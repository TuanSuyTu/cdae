`timescale 1ns/1ps

// ==========================================================
// Module: Unified RAM
// Purpose:
//   Day la wrapper boc UltraRAM 32-bit.
//   Dong vai tro nhu mot bo nho Shared Memory cho toan bo
//   he thong thay the cho khoi PS DDR cham chap.
// ==========================================================
module cdae_unified_ram (
    input  wire        clk,

    input  wire        ena,
    input  wire [20:0] addra,
    output reg  [31:0] douta,

    input  wire        wec,
    input  wire [20:0] addrc,
    input  wire [31:0] dinc
);

    // ==========================================================
    // Memory Array: UltraRAM
    // Purpose:
    //   Su dung UltraRAM (URAM) thay vi BlockRAM (BRAM) tren FPGA.
    //   Kich thuoc 165000 tu 32-bit (chua Input, Output va cac Buffer).
    //   Cho phep doc va ghi doc lap, dong thoi (Simultaneous) qua 2 port A va C.
    // ==========================================================
    localparam MEM_DEPTH = 165000;
    (* ram_style = "ultra", cascade_height = 1 *) reg [31:0] mem_a [0:MEM_DEPTH-1];

    // Memory does not need explicit zero-initialization

    always @(posedge clk) begin
        if (wec) mem_a[addrc] <= dinc;
    end
    always @(posedge clk) begin
        if (ena) douta <= mem_a[addra];
    end

endmodule
