// ==========================================================
// File: CDAE Kria KV260 Linux Driver (DEBUG VERSION)
// Purpose:
//   Phien ban debug cua cdae_driver.c, them cac chuc nang:
//   1. Timeout cho vong lap cho done (tranh treo cung)
//   2. Xac minh du lieu RAM sau khi ghi (verify readback)
//   3. In REG_STATUS lien tuc de chan doan
// ==========================================================
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>

#define CDAE_BASE_ADDR 0xA0000000
#define CDAE_MAP_SIZE  0x1000

#define REG_CTRL   0x00
#define REG_STATUS 0x04
#define REG_ADDR   0x08
#define REG_WDATA  0x0C
#define REG_RDATA  0x10

#define RAM_ADDR_INP   0
#define RAM_ADDR_OUT   122000
#define TILE_PIXELS    9408

#define IMG_W 224
#define IMG_H 224
#define IMG_C 3
#define IMG_PIXELS (IMG_W * IMG_H * IMG_C)
#define TILE_W 56
#define TILE_H 56
#define TILE_GRID_W (IMG_W / TILE_W)
#define TILE_GRID_H (IMG_H / TILE_H)
#define NUM_TILES (TILE_GRID_W * TILE_GRID_H)

// Timeout: so lan doc REG_STATUS toi da truoc khi bo cuoc
#define POLL_TIMEOUT     100000000
// So pixel xac minh o dau va cuoi mang input
#define VERIFY_COUNT     5

#define AXI_WRITE(base, offset, data) (*(volatile uint32_t *)((uint8_t *)(base) + (offset)) = (uint32_t)(data))
#define AXI_READ(base, offset)        (*(volatile uint32_t *)((uint8_t *)(base) + (offset)))

uint16_t float_to_q12(float val) {
    if (val > 1.0f) val = 1.0f;
    if (val < 0.0f) val = 0.0f;
    return (uint16_t)(val * 4096.0f);
}

float q12_to_float(uint16_t val) {
    return (float)val / 4096.0f;
}

void extract_tile(const float *src_image, float *dst_tile, int ty, int tx) {
    for (int dy = 0; dy < TILE_H; dy++) {
        for (int dx = 0; dx < TILE_W; dx++) {
            for (int c = 0; c < IMG_C; c++) {
                int src_y = ty * TILE_H + dy;
                int src_x = tx * TILE_W + dx;
                int src_idx = (src_y * IMG_W + src_x) * IMG_C + c;
                int dst_idx = (dy * TILE_W + dx) * IMG_C + c;
                dst_tile[dst_idx] = src_image[src_idx];
            }
        }
    }
}

void insert_tile(const float *src_tile, float *dst_image, int ty, int tx) {
    for (int dy = 0; dy < TILE_H; dy++) {
        for (int dx = 0; dx < TILE_W; dx++) {
            for (int c = 0; c < IMG_C; c++) {
                int dst_y = ty * TILE_H + dy;
                int dst_x = tx * TILE_W + dx;
                int dst_idx = (dst_y * IMG_W + dst_x) * IMG_C + c;
                int src_idx = (dy * TILE_W + dx) * IMG_C + c;
                dst_image[dst_idx] = src_tile[src_idx];
            }
        }
    }
}

// ==========================================================
// Function: verify_ram_readback
// Purpose:
//   Doc lai mot so pixel tu RAM sau khi ghi de xac minh
//   du lieu da duoc luu dung hay chua.
//   Tra ve so luong pixel bi sai.
// ==========================================================
int verify_ram_readback(void *cdae_base, float *tile_in, int count) {
    int errors = 0;
    printf("[VERIFY] Kiem tra %d pixel dau...\n", count);
    for (int i = 0; i < count && i < TILE_PIXELS; i++) {
        uint16_t expected = float_to_q12(tile_in[i]);
        AXI_WRITE(cdae_base, REG_ADDR, RAM_ADDR_INP + i);
        usleep(1);  // Cho RAM co thoi gian cap nhat port doc
        uint32_t raw = AXI_READ(cdae_base, REG_RDATA);
        uint16_t actual = (uint16_t)(raw & 0xFFFF);
        if (expected != actual) {
            printf("  [FAIL] pixel[%d]: ghi=0x%04x, doc=0x%04x (raw=0x%08x)\n",
                   i, expected, actual, raw);
            errors++;
        } else {
            printf("  [OK]   pixel[%d]: 0x%04x\n", i, actual);
        }
    }

    printf("[VERIFY] Kiem tra %d pixel cuoi...\n", count);
    for (int i = TILE_PIXELS - count; i < TILE_PIXELS; i++) {
        if (i < 0) continue;
        uint16_t expected = float_to_q12(tile_in[i]);
        AXI_WRITE(cdae_base, REG_ADDR, RAM_ADDR_INP + i);
        usleep(1);
        uint32_t raw = AXI_READ(cdae_base, REG_RDATA);
        uint16_t actual = (uint16_t)(raw & 0xFFFF);
        if (expected != actual) {
            printf("  [FAIL] pixel[%d]: ghi=0x%04x, doc=0x%04x (raw=0x%08x)\n",
                   i, expected, actual, raw);
            errors++;
        } else {
            printf("  [OK]   pixel[%d]: 0x%04x\n", i, actual);
        }
    }
    return errors;
}

// ==========================================================
// Function: poll_status_with_timeout
// Purpose:
//   Doi REG_STATUS bit 0 (done_inference) len 1.
//   In trang thai moi 0.5 giay. Thoat khi timeout.
//   Tra ve 1 neu thanh cong, 0 neu timeout.
// ==========================================================
int poll_status_with_timeout(void *cdae_base, int timeout_seconds) {
    struct timespec t_start, t_now;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    int last_print_sec = -1;
    uint32_t status = 0;
    long long poll_count = 0;

    while (1) {
        status = AXI_READ(cdae_base, REG_STATUS);

        // Bit 1 = inference_busy. Doi cho den khi busy = 0
        if ((status & 0x02) == 0) {
            printf("[DONE] Inference hoan thanh! STATUS=0x%08x (polls=%lld)\n",
                   status, poll_count);
            return 1;
        }

        poll_count++;

        // In trang thai moi 0.5 giay
        clock_gettime(CLOCK_MONOTONIC, &t_now);
        double elapsed = (t_now.tv_sec - t_start.tv_sec) +
                         (t_now.tv_nsec - t_start.tv_nsec) / 1e9;

        int current_half_sec = (int)(elapsed * 2);
        if (current_half_sec != last_print_sec) {
            last_print_sec = current_half_sec;
            printf("[POLL] t=%.1fs: STATUS=0x%08x  done=%d busy=%d  polls=%lld\n",
                   elapsed, status, status & 1, (status >> 1) & 1, poll_count);
        }

        // Kiem tra timeout
        if (elapsed >= timeout_seconds) {
            printf("[TIMEOUT] Da cho %d giay. STATUS=0x%08x  done=%d busy=%d\n",
                   timeout_seconds, status, status & 1, (status >> 1) & 1);
            printf("[TIMEOUT] Tong so lan doc STATUS: %lld\n", poll_count);
            return 0;
        }
    }
}

int main() {

    struct timespec t_start_total, t_end_total;
    struct timespec t_start_write, t_end_write;
    struct timespec t_start_calc,  t_end_calc;
    struct timespec t_start_read,  t_end_read;
    double time_write, time_calc, time_read, time_total;

    printf("=== CDAE Driver DEBUG VERSION ===\n");
    printf("--- Khoi dong CDAE Driver tren Kria KV260 ---\n");

    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("Khong the mo /dev/mem, can chay bang sudo");
        return -1;
    }

    void *cdae_base = mmap(NULL, CDAE_MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, CDAE_BASE_ADDR);
    if (cdae_base == MAP_FAILED) {
        perror("mmap that bai");
        close(mem_fd);
        return -1;
    }

    printf("[+] Da map phan cung tai dia chi ao: %p\n", cdae_base);

    // --- DEBUG: Doc gia tri ban dau cua cac thanh ghi ---
    printf("\n[DEBUG] Gia tri ban dau cac thanh ghi:\n");
    printf("  REG_CTRL   (0x00) = 0x%08x\n", AXI_READ(cdae_base, REG_CTRL));
    printf("  REG_STATUS (0x04) = 0x%08x\n", AXI_READ(cdae_base, REG_STATUS));
    printf("  REG_ADDR   (0x08) = 0x%08x\n", AXI_READ(cdae_base, REG_ADDR));
    printf("  REG_RDATA  (0x10) = 0x%08x\n", AXI_READ(cdae_base, REG_RDATA));

    float *input_image = (float *)malloc(IMG_PIXELS * sizeof(float));
    float *output_image = (float *)malloc(IMG_PIXELS * sizeof(float));
    float tile_in[TILE_PIXELS];
    float tile_out[TILE_PIXELS];

    if (!input_image || !output_image) {
        perror("Cap phat bo nho cho anh that bai");
        munmap(cdae_base, CDAE_MAP_SIZE);
        close(mem_fd);
        return -1;
    }

    FILE *f_inp = fopen("input.bin", "rb");
    if (!f_inp) {
        perror("Khong the mo file input.bin");
        free(input_image);
        free(output_image);
        munmap(cdae_base, CDAE_MAP_SIZE);
        close(mem_fd);
        return -1;
    }
    size_t read_bytes = fread(input_image, sizeof(float), IMG_PIXELS, f_inp);
    fclose(f_inp);

    if (read_bytes != IMG_PIXELS) {
        printf("[!] Loi: Chi doc duoc %zu phan tu tu input.bin\n", read_bytes);
        free(input_image);
        free(output_image);
        munmap(cdae_base, CDAE_MAP_SIZE);
        close(mem_fd);
        return -1;
    }

    double total_time_write = 0.0;
    double total_time_calc = 0.0;
    double total_time_read = 0.0;
    double total_time_total = 0.0;

    printf("\n[+] Bat dau xu ly %d tiles tu anh %dx%dx%d...\n",
           NUM_TILES, IMG_W, IMG_H, IMG_C);

    for (int ty = 0; ty < TILE_GRID_H; ty++) {
        for (int tx = 0; tx < TILE_GRID_W; tx++) {
            int tile_idx = ty * TILE_GRID_W + tx;
            printf("\n========== TILE %d/%d (ty=%d, tx=%d) ==========\n",
                   tile_idx + 1, NUM_TILES, ty, tx);

            clock_gettime(CLOCK_MONOTONIC, &t_start_total);

            extract_tile(input_image, tile_in, ty, tx);

            // --- PHASE 1: Ghi du lieu input vao RAM ---
            printf("[1/3] Dang ghi %d pixel vao RAM...\n", TILE_PIXELS);
            clock_gettime(CLOCK_MONOTONIC, &t_start_write);
            for (uint32_t i = 0; i < TILE_PIXELS; i++) {
                uint16_t q12_val = float_to_q12(tile_in[i]);
                AXI_WRITE(cdae_base, REG_ADDR, RAM_ADDR_INP + i);
                AXI_WRITE(cdae_base, REG_WDATA, q12_val);
            }
            clock_gettime(CLOCK_MONOTONIC, &t_end_write);
            time_write = (t_end_write.tv_sec - t_start_write.tv_sec) * 1000.0 +
                         (t_end_write.tv_nsec - t_start_write.tv_nsec) / 1000000.0;
            printf("[1/3] Ghi xong trong %.3f ms\n", time_write);

            // --- DEBUG: Xac minh du lieu RAM ---
            int verify_errors = verify_ram_readback(cdae_base, tile_in, VERIFY_COUNT);
            if (verify_errors > 0) {
                printf("[CAUTION] Co %d pixel bi sai! Du lieu RAM khong dang tin cay.\n",
                       verify_errors);
                printf("[CAUTION] Tiep tuc chay de quan sat hanh vi...\n");
            } else {
                printf("[VERIFY] Tat ca pixel kiem tra deu DUNG.\n");
            }

            // --- DEBUG: Doc lai REG_STATUS truoc khi start ---
            uint32_t pre_status = AXI_READ(cdae_base, REG_STATUS);
            printf("[DEBUG] REG_STATUS truoc khi start: 0x%08x (done=%d, busy=%d)\n",
                   pre_status, pre_status & 1, (pre_status >> 1) & 1);

            // --- PHASE 2: Kich hoat inference ---
            printf("[2/3] Kich hoat inference (REG_CTRL=1)...\n");
            clock_gettime(CLOCK_MONOTONIC, &t_start_calc);
            AXI_WRITE(cdae_base, REG_CTRL, 1);

            // --- DEBUG: Doc REG_STATUS ngay sau khi start ---
            usleep(100);  // Cho 100us de FPGA xu ly start_pulse
            uint32_t post_status = AXI_READ(cdae_base, REG_STATUS);
            printf("[DEBUG] REG_STATUS ngay sau start: 0x%08x (done=%d, busy=%d)\n",
                   post_status, post_status & 1, (post_status >> 1) & 1);

            // --- Poll voi timeout 30 giay ---
            int success = poll_status_with_timeout(cdae_base, 30);
            clock_gettime(CLOCK_MONOTONIC, &t_end_calc);

            if (!success) {
                printf("\n[ABORT] Inference bi treo! Dung lai de phan tich.\n");
                printf("[ABORT] Hay kiem tra:\n");
                printf("  1. Dia chi AXI base co dung 0x%08x khong? (xem Vivado Address Editor)\n",
                       CDAE_BASE_ADDR);
                printf("  2. Bitstream da nap dung chua? (cat /sys/class/fpga_manager/fpga0/state)\n");
                printf("  3. Clock PL co dang chay khong?\n");

                // Giai phong tai nguyen truoc khi thoat
                free(input_image);
                free(output_image);
                munmap(cdae_base, CDAE_MAP_SIZE);
                close(mem_fd);
                return -1;
            }

            time_calc = (t_end_calc.tv_sec - t_start_calc.tv_sec) * 1000.0 +
                        (t_end_calc.tv_nsec - t_start_calc.tv_nsec) / 1000000.0;
            printf("[2/3] Inference hoan thanh trong %.3f ms\n", time_calc);

            // --- PHASE 3: Doc ket qua output ---
            printf("[3/3] Dang doc %d pixel output tu RAM...\n", TILE_PIXELS);
            clock_gettime(CLOCK_MONOTONIC, &t_start_read);
            AXI_WRITE(cdae_base, REG_ADDR, RAM_ADDR_OUT);
            uint32_t dummy_read = AXI_READ(cdae_base, REG_RDATA);

            for (uint32_t i = 0; i < TILE_PIXELS; i++) {
                if (i < TILE_PIXELS - 1) {
                    AXI_WRITE(cdae_base, REG_ADDR, RAM_ADDR_OUT + i + 1);
                }
                uint32_t raw_data = AXI_READ(cdae_base, REG_RDATA);
                uint16_t q12_out = (uint16_t)(raw_data & 0xFFFF);
                tile_out[i] = q12_to_float(q12_out);
            }
            clock_gettime(CLOCK_MONOTONIC, &t_end_read);

            insert_tile(tile_out, output_image, ty, tx);

            clock_gettime(CLOCK_MONOTONIC, &t_end_total);

            time_read  = (t_end_read.tv_sec - t_start_read.tv_sec) * 1000.0 +
                         (t_end_read.tv_nsec - t_start_read.tv_nsec) / 1000000.0;
            time_total = (t_end_total.tv_sec - t_start_total.tv_sec) * 1000.0 +
                         (t_end_total.tv_nsec - t_start_total.tv_nsec) / 1000000.0;

            printf("[3/3] Doc xong trong %.3f ms\n", time_read);
            printf("[TILE %d] Tong: %.3f ms (ghi=%.3f, tinh=%.3f, doc=%.3f)\n",
                   tile_idx + 1, time_total, time_write, time_calc, time_read);

            total_time_write += time_write;
            total_time_calc  += time_calc;
            total_time_read  += time_read;
            total_time_total += time_total;
        }
    }

    printf("\n[+] Da xu ly xong tat ca cac tile!\n");

    FILE *f_out = fopen("output.bin", "wb");
    if (!f_out) {
        perror("Khong the mo file output.bin");
    } else {
        fwrite(output_image, sizeof(float), IMG_PIXELS, f_out);
        fclose(f_out);
        printf("[+] Da ghi ket qua vao output.bin\n");
    }

    double bytes_total_comm = IMG_PIXELS * 2.0;

    double bw_write = (bytes_total_comm / 1048576.0) / (total_time_write / 1000.0);
    double bw_read  = (bytes_total_comm / 1048576.0) / (total_time_read / 1000.0);
    double bw_total = (bytes_total_comm * 2.0 / 1048576.0) / ((total_time_write + total_time_read) / 1000.0);

    double fps = 1000.0 / total_time_total;

    printf("\n================ BANG THONG KE HIEU NANG =================\n");
    printf("[1] THOI GIAN XU LY TONG CO HIEU 16 TILES:\n");
    printf("    - Ghi data PS sang PL  : %10.3f ms\n", total_time_write);
    printf("    - Tinh toan FPGA Core  : %10.3f ms\n", total_time_calc);
    printf("    - Doc data PL sang PS  : %10.3f ms\n", total_time_read);
    printf("    -> Tong thoi gian      : %10.3f ms\n\n", total_time_total);

    printf("[2] BANG THONG GIAO TIEP THROUGHPUT:\n");
    printf("    - Toc do ghi Input     : %10.3f MB/s\n", bw_write);
    printf("    - Toc do doc Output    : %10.3f MB/s\n", bw_read);
    printf("    -> Bang thong trung binh: %10.3f MB/s\n\n", bw_total);

    printf("[3] TOC DO KHUNG HINH FPS CHO ANH 224x224:\n");
    printf("    -> FPS dat duoc        : %10.2f frames/s\n", fps);
    printf("==========================================================\n\n");

    free(input_image);
    free(output_image);
    munmap(cdae_base, CDAE_MAP_SIZE);
    close(mem_fd);

    return 0;
}
