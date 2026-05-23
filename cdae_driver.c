#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>

// Cấu hình AXI4-Lite
#define CDAE_BASE_ADDR 0xA0000000 
#define CDAE_MAP_SIZE  0x1000

#define REG_CTRL   0x00
#define REG_STATUS 0x04
#define REG_ADDR   0x08
#define REG_WDATA  0x0C
#define REG_RDATA  0x10

#define RAM_ADDR_INP   0
#define RAM_ADDR_OUT   122000

#define IMG_W 224
#define IMG_H 224
#define CHANNELS 3
#define TILE_W 56
#define TILE_H 56
#define TILE_PIXELS (TILE_W * TILE_H * CHANNELS)
#define NUM_TILES_W (IMG_W / TILE_W)
#define NUM_TILES_H (IMG_H / TILE_H)
#define TOTAL_PIXELS (IMG_W * IMG_H * CHANNELS)

#define AXI_WRITE(base, offset, data) (*(volatile uint32_t *)((uint8_t *)(base) + (offset)) = (uint32_t)(data))
#define AXI_READ(base, offset)        (*(volatile uint32_t *)((uint8_t *)(base) + (offset)))

uint16_t float_to_q12(float val) {
    if (val > 1.0f) val = 1.0f;
    if (val < 0.0f) val = 0.0f;
    return (uint16_t)(val * 4096.0f);
}

float q12_to_float(uint16_t val) {
    // Ép kiểu sang int16_t có dấu trước khi chia để xử lý đúng số âm nếu có
    int16_t sval = (int16_t)val;
    return (float)sval / 4096.0f;
}

int main() {
    printf("--- Khởi động CDAE Image Driver (224x224) ---\n");

    // 1. Đọc file ảnh đầu vào (dạng binary float)
    float *full_img_in = (float *)malloc(TOTAL_PIXELS * sizeof(float));
    float *full_img_out = (float *)malloc(TOTAL_PIXELS * sizeof(float));
    
    FILE *fin = fopen("input.bin", "rb");
    if (!fin) {
        printf("Lỗi: Không tìm thấy file input.bin! Chạy script Python img_to_bin.py trước.\n");
        return -1;
    }
    fread(full_img_in, sizeof(float), TOTAL_PIXELS, fin);
    fclose(fin);

    // 2. Map Memory
    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) return -1;
    void *cdae_base = mmap(NULL, CDAE_MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, CDAE_BASE_ADDR);
    if (cdae_base == MAP_FAILED) return -1;

    // 3. Xử lý 16 Tiles
    int tile_count = 0;
    for (int ty = 0; ty < NUM_TILES_H; ty++) {
        for (int tx = 0; tx < NUM_TILES_W; tx++) {
            printf("[Tile %d/16] Đang xử lý toạ độ X:%d, Y:%d...\n", ++tile_count, tx, ty);

            // 3a. Trích xuất Tile 56x56 và Nạp xuống FPGA
            for (int h = 0; h < TILE_H; h++) {
                for (int w = 0; w < TILE_W; w++) {
                    for (int c = 0; c < CHANNELS; c++) {
                        int img_x = (tx * TILE_W) + w;
                        int img_y = (ty * TILE_H) + h;
                        int idx_full = (img_y * IMG_W + img_x) * CHANNELS + c;
                        int idx_tile = c * (TILE_H * TILE_W) + h * TILE_W + w;

                        float pixel = full_img_in[idx_full];
                        AXI_WRITE(cdae_base, REG_ADDR, RAM_ADDR_INP + idx_tile);
                        AXI_WRITE(cdae_base, REG_WDATA, float_to_q12(pixel));
                    }
                }
            }

            // 3b. Chạy Inference
            AXI_WRITE(cdae_base, REG_CTRL, 1);
            
            // SỬA LỖI RACE CONDITION: CPU chạy quá nhanh, đọc STATUS trước khi FSM kịp dựng cờ Busy
            // Bước 1: Chờ FSM xác nhận đã bắt đầu (Busy lên 1)
            while (!(AXI_READ(cdae_base, REG_STATUS) & 0x02)); 
            // Bước 2: Chờ FSM chạy xong (Busy rớt xuống 0)
            while ((AXI_READ(cdae_base, REG_STATUS) & 0x02)); 

            // 3c. Đọc Kết quả từ FPGA
            for (int h = 0; h < TILE_H; h++) {
                for (int w = 0; w < TILE_W; w++) {
                    for (int c = 0; c < CHANNELS; c++) {
                        int img_x = (tx * TILE_W) + w;
                        int img_y = (ty * TILE_H) + h;
                        int idx_full = (img_y * IMG_W + img_x) * CHANNELS + c;
                        int idx_tile = c * (TILE_H * TILE_W) + h * TILE_W + w;

                        // SỬA LỖI DUMMY READ: CPU chậm hơn RAM nên không cần đọc gối đầu
                        AXI_WRITE(cdae_base, REG_ADDR, RAM_ADDR_OUT + idx_tile);
                        uint32_t raw_data = AXI_READ(cdae_base, REG_RDATA);
                        full_img_out[idx_full] = q12_to_float((uint16_t)(raw_data & 0xFFFF));
                    }
                }
            }
        }
    }

    // 4. Lưu ảnh kết quả ra file nhị phân
    FILE *fout = fopen("output.bin", "wb");
    fwrite(full_img_out, sizeof(float), TOTAL_PIXELS, fout);
    fclose(fout);

    printf("[+] Xử lý hoàn tất 16 Tiles. Đã lưu kết quả ra 'output.bin'.\n");

    munmap(cdae_base, CDAE_MAP_SIZE);
    close(mem_fd);
    free(full_img_in);
    free(full_img_out);
    
    return 0;
}
