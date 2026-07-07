`timescale 1ns/1ps

// ==========================================================
// Module: Elementwise Addition
// Purpose:
//   Cong 2 tensor cung kich thuoc (A + B).
//   Dung trong Residual Connection hoac gop dac trung.
//   Delay 1 cycle de can bang timing tren FPGA.
// ==========================================================
module add_layer #(
    parameter int DATA_W = 32
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire signed [DATA_W-1:0]  a_in,
    input  wire                      a_vld,
    output wire                      a_rdy,

    input  wire signed [DATA_W-1:0]  b_in,
    input  wire                      b_vld,
    output wire                      b_rdy,

    output wire signed [DATA_W-1:0]  out,
    output wire                      out_vld,
    input  wire                      out_rdy
);

    // ==========================================================
    // Block: Internal Declarations & Helper Functions
    // ==========================================================
    logic signed [DATA_W:0] sum_ext;

    function automatic logic signed [DATA_W-1:0] sat_add(
        input logic signed [DATA_W:0] v
    );
        if (v > $signed({{1'b0}, {(DATA_W-1){1'b1}}})) sat_add = {1'b0, {(DATA_W-1){1'b1}}};
        else if (v < $signed({{1'b1}, {(DATA_W-1){1'b0}}})) sat_add = {1'b1, {(DATA_W-1){1'b0}}};
        else sat_add = v[DATA_W-1:0];
    endfunction

    // ==========================================================
    // Block: Combinational Addition
    // Purpose: Cong vector va chong tran so (Saturation).
    // ==========================================================
    logic signed [DATA_W-1:0] out_reg;
    logic                     out_vld_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_reg     <= '0;
            out_vld_reg <= 1'b0;
        end else begin
            if (out_rdy || !out_vld_reg) begin
                out_reg     <= sat_add(sum_ext);
                out_vld_reg <= a_vld && b_vld;
            end
        end
    end

    assign sum_ext = $signed({a_in[DATA_W-1], a_in}) + $signed({b_in[DATA_W-1], b_in});

    assign out     = out_reg;
    assign out_vld = out_vld_reg;
    assign a_rdy   = out_rdy || !out_vld_reg;
    assign b_rdy   = out_rdy || !out_vld_reg;

endmodule
