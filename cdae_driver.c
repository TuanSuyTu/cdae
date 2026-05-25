#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mmap.h>

// =========================================================
// Cấu hình thanh ghi AXI4-Lite (Dựa trên cdae_axi_wrapper.v)
// =========================================================
// LƯU Ý: Thay thế địa chỉ này bằng địa chỉ thật trong tab 
// Address Editor của Vivado Block Design (VD: 0x40000000)
#define CDAE_BASE_ADDR 0xA0000000 
#define CDAE_MAP_SIZE  0x1000

// Offsets thanh ghi
#define REG_CTRL   0x00  // [W] Bit 0: Start
#define REG_STATUS 0x04  // [R] Bit 0: Done, Bit 1: Busy
#define REG_ADDR   0x08  // [RW] 21-bit địa chỉ RAM nội bộ
#define REG_WDATA  0x0C  // [W] 16-bit Data vào
#define REG_RDATA  0x10  // [R] 16-bit Data ra

// Offsets vùng nhớ trong Unified RAM
#define RAM_ADDR_INP   0       // Bắt đầu lưu Input Tile
#define RAM_ADDR_OUT   122000  // Bắt đầu lưu Output Tile
#define TILE_PIXELS    9408    // 56 * 56 * 3

// Macro đọc/ghi AXI
#define AXI_WRITE(base, offset, data) (*(volatile uint32_t *)((uint8_t *)(base) + (offset)) = (uint32_t)(data))
#define AXI_READ(base, offset)        (*(volatile uint32_t *)((uint8_t *)(base) + (offset)))

// Chuyển đổi Float sang Fixed-point (Q4.12 để đẩy qua 16-bit)
// Vì giá trị pixel trong khoảng [0.0, 1.0], 1.0 = 4096
uint16_t float_to_q12(float val) {
    if (val > 1.0f) val = 1.0f;
    if (val < 0.0f) val = 0.0f;
    return (uint16_t)(val * 4096.0f);
}

// Chuyển đổi Fixed-point Q4.12 sang Float
float q12_to_float(uint16_t val) {
    return (float)val / 4096.0f;
}

int main() {
    printf("--- Khoi dong CDAE Driver tren Kria KV260 ---\n");

    // 1. Mở /dev/mem để map memory vật lý (Cho PetaLinux/Ubuntu)
    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("Khong the mo /dev/mem (Chay bang sudo?)");
        return -1;
    }

    // 2. Map địa chỉ AXI vào Virtual Memory của User-space
    void *cdae_base = mmap(NULL, CDAE_MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, CDAE_BASE_ADDR);
    if (cdae_base == MAP_FAILED) {
        perror("mmap that bai");
        close(mem_fd);
        return -1;
    }

    printf("[+] Da map phan cung tai dia chi ao: %p\n", cdae_base);

    // =========================================================
    // PHA 1: CHUẨN BỊ DỮ LIỆU VÀ NẠP XUỐNG FPGA
    // =========================================================
    printf("[+] Dang nap tile 56x56x3 xuong FPGA RAM...\n");
    for (uint32_t i = 0; i < TILE_PIXELS; i++) {
        // Mock data: Tạo một giá trị pixel giả lập từ 0.0 đến 1.0
        float dummy_pixel = (float)(i % 255) / 255.0f; 
        uint16_t q12_val = float_to_q12(dummy_pixel);

        // Set địa chỉ ghi
        AXI_WRITE(cdae_base, REG_ADDR, RAM_ADDR_INP + i);
        // Ghi dữ liệu 16-bit (Hardware sẽ tự động sinh xung write enable)
        AXI_WRITE(cdae_base, REG_WDATA, q12_val);
    }
    printf("[+] Nap du lieu hoan tat!\n");

    // =========================================================
    // PHA 2: RA LỆNH CHẠY INFERENCE
    // =========================================================
    printf("[+] Bat dau qua trinh Inference (19 layers)...\n");
    // Ghi bit 1 vào CTRL register để kích start_inference
    AXI_WRITE(cdae_base, REG_CTRL, 1);

    // =========================================================
    // PHA 3: CHỜ HOÀN THÀNH (POLLING)
    // =========================================================
    uint32_t status = 0;
    while (1) {
        status = AXI_READ(cdae_base, REG_STATUS);
        if (status & 0x01) { // Bit 0 là done_inference
            break;
        }
    }
    printf("[+] Inference hoan tat! Dang doc ket qua...\n");

    // =========================================================
    // PHA 4: ĐỌC DỮ LIỆU KẾT QUẢ TỪ FPGA
    // =========================================================
    float output_tile[TILE_PIXELS];
    
    // Gửi địa chỉ đầu tiên cần đọc để mồi (pipeline read của RAM mất 2 cycle)
    AXI_WRITE(cdae_base, REG_ADDR, RAM_ADDR_OUT);
    uint32_t dummy_read = AXI_READ(cdae_base, REG_RDATA); // Dummy read cycle 1

    for (uint32_t i = 0; i < TILE_PIXELS; i++) {
        // Chuẩn bị địa chỉ cho chu kỳ tiếp theo (để đọc gối đầu)
        if (i < TILE_PIXELS - 1) {
            AXI_WRITE(cdae_base, REG_ADDR, RAM_ADDR_OUT + i + 1);
        }

        // Đọc data của địa chỉ hiện tại
        uint32_t raw_data = AXI_READ(cdae_base, REG_RDATA);
        uint16_t q12_out = (uint16_t)(raw_data & 0xFFFF);
        
        output_tile[i] = q12_to_float(q12_out);
    }

    // In thử 5 giá trị đầu tiên
    printf("[+] Doc hoan tat. 5 pixel ket qua dau tien:\n");
    for (int i = 0; i < 5; i++) {
        printf("    Pixel[%d] = %f\n", i, output_tile[i]);
    }

    // 5. Cleanup
    munmap(cdae_base, CDAE_MAP_SIZE);
    close(mem_fd);
    
    return 0;
}
