`timescale 1ns/1ps

// ==========================================================
// Module: Weight ROM -- Phien ban Parallel Pf=16
// Purpose:
//   Luu tru toan bo Weight va Bias cua mang Neural Network.
//   Khoi tao tu file 'weights.mem' (format interleaved 16-way).
//   Moi lan doc tra ve 16 gia tri 16-bit = 256-bit dong thoi.
// ==========================================================
module weight_rom #(
    parameter PF = 16   // He so song song -- so filter xu ly dong thoi
) (
    input  wire        clk,
    input  wire [16:0] addr,
    output reg  [PF*16-1:0] dout    // 256-bit output: 16 x 16-bit weights
);
    // Tong so tu sau padding tu python script: 95536 tu 16-bit
    // Sau khi gop nhom PF=16: 95536 / 16 = 5971 tu 256-bit
    localparam WEIGHT_TOTAL_WIDE = 5971;
    // Fix Timing: Ngan chan Vivado cascade BRAM qua dai gay fail timing
    (* rom_style = "block" *) reg [PF*16-1:0] mem [0:WEIGHT_TOTAL_WIDE-1];

    initial begin
        $readmemh("e:/VSCode/DoAn/CDAE/VIvado/src/weights.mem", mem);
    end

    always @(posedge clk)
        dout <= mem[addr[12:0]];

endmodule
