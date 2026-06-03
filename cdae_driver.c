// ==========================================================
// File: CDAE Kria KV260 Linux Driver
// Purpose:
//   Chuong trinh C chay tren he dieu hanh Linux cua KV260.
//   Su dung /dev/mem de map khong gian dia chi vat ly cua AXI
//   vao khong gian ao cua chuong trinh.
//   Dung de ghi Input, kich hoat Hardware va doc Output.
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
    // dst_tile gui xuong FPGA phai la dang CHW (Channel-Height-Width)
    // src_image doc tu file bin dang la HWC (Height-Width-Channel)
    for (int c = 0; c < IMG_C; c++) {
        for (int dy = 0; dy < TILE_H; dy++) {
            for (int dx = 0; dx < TILE_W; dx++) {
                int src_y = ty * TILE_H + dy;
                int src_x = tx * TILE_W + dx;
                int src_idx = (src_y * IMG_W + src_x) * IMG_C + c;
                int dst_idx = (c * TILE_H + dy) * TILE_W + dx;
                dst_tile[dst_idx] = src_image[src_idx];
            }
        }
    }
}

void insert_tile(const float *src_tile, float *dst_image, int ty, int tx) {
    // src_tile nhan tu FPGA la dang CHW
    // dst_image ghi ra file bin phai la HWC
    for (int c = 0; c < IMG_C; c++) {
        for (int dy = 0; dy < TILE_H; dy++) {
            for (int dx = 0; dx < TILE_W; dx++) {
                int dst_y = ty * TILE_H + dy;
                int dst_x = tx * TILE_W + dx;
                int dst_idx = (dst_y * IMG_W + dst_x) * IMG_C + c;
                int src_idx = (c * TILE_H + dy) * TILE_W + dx;
                dst_image[dst_idx] = src_tile[src_idx];
            }
        }
    }
}

int main() {

    struct timespec t_start_total, t_end_total;
    struct timespec t_start_write, t_end_write;
    struct timespec t_start_calc,  t_end_calc;
    struct timespec t_start_read,  t_end_read;
    double time_write, time_calc, time_read, time_total;

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

    printf("[+] Bat dau xu ly 16 tiles tu anh 224x224x3...\n");

    for (int ty = 0; ty < TILE_GRID_H; ty++) {
        for (int tx = 0; tx < TILE_GRID_W; tx++) {
            
            clock_gettime(CLOCK_MONOTONIC, &t_start_total);

            extract_tile(input_image, tile_in, ty, tx);

            clock_gettime(CLOCK_MONOTONIC, &t_start_write);
            for (uint32_t i = 0; i < TILE_PIXELS; i++) {
                uint16_t q12_val = float_to_q12(tile_in[i]);
                AXI_WRITE(cdae_base, REG_ADDR, RAM_ADDR_INP + i);
                AXI_WRITE(cdae_base, REG_WDATA, q12_val);
            }
            clock_gettime(CLOCK_MONOTONIC, &t_end_write);

            clock_gettime(CLOCK_MONOTONIC, &t_start_calc);
            AXI_WRITE(cdae_base, REG_CTRL, 1);

            uint32_t status = 0;
            // Cho tin hieu busy len 1 de chac chan da nhan start
            while (1) {
                status = AXI_READ(cdae_base, REG_STATUS);
                if (status & 0x02) { // Kiem tra bit 1 (busy)
                    break;
                }
            }
            // Cho tin hieu busy ve 0 de biet da tinh xong
            while (1) {
                status = AXI_READ(cdae_base, REG_STATUS);
                if ((status & 0x02) == 0) { // Kiem tra bit 1 (busy)
                    break;
                }
            }
            clock_gettime(CLOCK_MONOTONIC, &t_end_calc);

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

            time_write = (t_end_write.tv_sec - t_start_write.tv_sec) * 1000.0 + (t_end_write.tv_nsec - t_start_write.tv_nsec) / 1000000.0;
            time_calc  = (t_end_calc.tv_sec - t_start_calc.tv_sec)   * 1000.0 + (t_end_calc.tv_nsec - t_start_calc.tv_nsec)   / 1000000.0;
            time_read  = (t_end_read.tv_sec - t_start_read.tv_sec)   * 1000.0 + (t_end_read.tv_nsec - t_start_read.tv_nsec)   / 1000000.0;
            time_total = (t_end_total.tv_sec - t_start_total.tv_sec) * 1000.0 + (t_end_total.tv_nsec - t_start_total.tv_nsec) / 1000000.0;

            total_time_write += time_write;
            total_time_calc  += time_calc;
            total_time_read  += time_read;
            total_time_total += time_total;
        }
    }

    printf("[+] Da xu ly xong tat ca cac tile!\n");

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
