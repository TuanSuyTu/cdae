`timescale 1ns/1ps

// ==========================================================
// Module: Sigmoid Activation (LUT-based)
// Purpose:
//   Thuc hien ham kich hoat Sigmoid de chuan hoa output ve [0, 1].
//   Su dung Bang tra cuu (Look-Up Table / ROM) de tiet kiem tai 
//   nguyen tinh toan thay vi dung bo chia float.
// ==========================================================
module sigmoid_lut #(
    parameter int DATA_W = 32,
    parameter int LUT_DEPTH = 4096,

    parameter string LUT_FILE = "e:/VSCode/DoAn/CDAE/VIvado/src/sigmoid_lut_q412.hex"
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire signed [DATA_W-1:0]  pixel_in,
    input  wire                      pixel_vld,
    output wire                      pixel_rdy,

    output wire signed [DATA_W-1:0]  pixel_out,
    output wire                      out_vld,
    input  wire                      out_rdy
);

    // ==========================================================
    // Block: Internal Declarations & Signals
    // ==========================================================
    (* ram_style = "block" *) logic signed [15:0] lut_mem [0:LUT_DEPTH-1];

    logic signed [DATA_W-1:0] out_reg;
    logic out_reg_vld;
    logic [11:0] lut_idx;

    assign pixel_rdy = (~out_reg_vld) || out_rdy;
    assign out_vld   = out_reg_vld;
    assign pixel_out = out_reg;

    // ==========================================================
    // Block: ROM Initialization
    // Purpose: Nap file du lieu .hex vao khoi RAM/ROM.
    // ==========================================================
    initial begin
        $readmemh(LUT_FILE, lut_mem);
    end

    logic signed [31:0] clamped;
    logic signed [16:0] shifted;

    // ==========================================================
    // Block: LUT Address Calculation
    // Purpose: Tinh toan chi so (Index) de tra cuu ROM.
    // ==========================================================
    always_comb begin

        if (pixel_in > 32'sd32767)
            clamped = 32'sd32767;
        else if (pixel_in < -32'sd32768)
            clamped = -32'sd32768;
        else
            clamped = pixel_in;

        shifted = $signed({clamped[15], clamped[15:0]}) + 17'sd32768;

        if (shifted <= 17'sd0)
            lut_idx = 12'd0;
        else if (shifted >= 17'sd65520)
            lut_idx = 12'd4095;
        else
            lut_idx = shifted[15:4];
    end

    // ==========================================================
    // Block: Output Register Pipeline
    // Purpose: Doc ROM va chot ket qua tra ve. Delay 1 cycle.
    // ==========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_reg     <= '0;
            out_reg_vld <= 1'b0;
        end
        else begin
            if (pixel_vld && pixel_rdy) begin

                out_reg     <= {{16{lut_mem[lut_idx][15]}}, lut_mem[lut_idx]};
                out_reg_vld <= 1'b1;
            end
            else if (out_reg_vld && out_rdy) begin
                out_reg_vld <= 1'b0;
            end
        end
    end

endmodule
