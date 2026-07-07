`timescale 1ns/1ps

// ==========================================================
// Module: ReLU6 Activation
// Purpose:
//   Thuc hien ham kich hoat Rectified Linear Unit.
//   Neu pixel < 0 => pixel = 0.
//   Kiep che (Clamp) ket qua o 6.0 de tranh tran so (ReLU6).
// ==========================================================
module relu #(

    parameter signed [31:0] MAX_VAL = 32'sd24576
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire signed [31:0] pixel_in,
    input  wire               pixel_vld,
    output wire               pixel_rdy,

    output wire signed [31:0] pixel_out,
    output wire               out_vld,
    input  wire               out_rdy
);

    // ==========================================================
    // Block: Combinational Activation
    // Purpose: So sanh va Clamp gia tri dong thoi gian thuc.
    // ==========================================================
    assign pixel_rdy = out_rdy;
    assign out_vld   = pixel_vld;

    assign pixel_out = (pixel_in < 32'sd0) ? 32'sd0 :
                       (pixel_in > MAX_VAL) ? MAX_VAL :
                       pixel_in;

endmodule
