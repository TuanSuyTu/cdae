`timescale 1ns/1ps

// ==========================================================
// Module: Weight Controller -- Phien ban Parallel Pf=8
// Purpose:
//   Quan ly viec phan phoi trong so (Weight) va Bias tu ROM
//   den cac module Conv. Theo doi Layer Index de cap nhat
//   dia chi doc ROM tuong ung cho tung vong lap.
//
// Thiet ke moi:
//   ROM output la 256-bit = 16 x 16-bit.
//   Controller phan phoi truc tiep 16 weights cho 16 MAC Engine.
//   Dia chi ROM bay gio la dia chi 256-bit (moi dia chi = 16 tu goc).
// ==========================================================
module weight_controller #(
    parameter PF = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [4:0]  layer_idx,
    input  wire        core_start,

    output wire [16:0] rom_addr,
    input  wire [PF*16-1:0] rom_data,   // 256-bit tu ROM

    output wire [PF*16-1:0] weight_out, // 256-bit: 16 weights dong thoi
    output wire        weight_vld,
    input  wire        weight_rdy
);

    // ==========================================================
    // Block: Layer Encodings
    // ==========================================================
    localparam ST_E1        = 5'd1;
    localparam ST_E2        = 5'd3;
    localparam ST_BOT1_C1   = 5'd5;
    localparam ST_BOT1_C2   = 5'd6;
    localparam ST_BOT1_SH   = 5'd7;
    localparam ST_BOT2_C1   = 5'd9;
    localparam ST_BOT2_C2   = 5'd10;
    localparam ST_D1        = 5'd12;
    localparam ST_D2        = 5'd13;
    localparam ST_NOISE_C1  = 5'd14;
    localparam ST_NOISE_C2  = 5'd15;
    localparam ST_R_C1      = 5'd17;
    localparam ST_R_C2      = 5'd18;

    // ==========================================================
    // 1. Cap nhat Base Address theo Layer (Lay tu Python gen script voi PF=16)
    //   Dia chi bay gio la dia chi 256-bit (chia 16 so voi dia chi goc).
    // ==========================================================
    reg [16:0] base_addr;
    always @(*) begin
        case (layer_idx)
            ST_E1:        base_addr = 17'd0;
            ST_E2:        base_addr = 17'd28;
            ST_BOT1_C1:   base_addr = 17'd318;
            ST_BOT1_C2:   base_addr = 17'd1185;
            ST_BOT1_SH:   base_addr = 17'd2268;
            ST_BOT2_C1:   base_addr = 17'd2367;
            ST_BOT2_C2:   base_addr = 17'd3450;
            ST_D1:        base_addr = 17'd4533;
            ST_D2:        base_addr = 17'd5255;
            ST_NOISE_C1:  base_addr = 17'd5544;
            ST_NOISE_C2:  base_addr = 17'd5689;
            ST_R_C1:      base_addr = 17'd5834;
            ST_R_C2:      base_addr = 17'd5862;
            default:      base_addr = 17'd0;
        endcase
    end

    reg [16:0] offset;
    reg        active;
    reg        rom_wait;

    reg [4:0] prev_layer_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) prev_layer_idx <= 5'd0;
        else        prev_layer_idx <= layer_idx;
    end
    wire layer_changed = (layer_idx != prev_layer_idx);

    // ==========================================================
    // Block: Sequential Offset Counters
    // Purpose: Quet tuan tu doc cac gia tri Weight sau khi core_start.
    //   Moi increment offset tuong ung voi doc 8 weights cung luc.
    // ==========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            offset <= 17'd0;
            active <= 1'b0;
            rom_wait <= 1'b0;
        end else if (core_start) begin
            offset <= 17'd0;
            active <= 1'b1;
            rom_wait <= 1'b0;
        end else if (layer_changed) begin
            offset <= 17'd0;
        end else if (active && weight_vld && weight_rdy) begin
            offset <= offset + 17'd1;
            rom_wait <= 1'b1;
        end else if (rom_wait) begin
            rom_wait <= 1'b0;
        end
    end

    assign rom_addr   = base_addr + offset;
    assign weight_out = rom_data;   // Truyen thang 128-bit tu ROM

    reg active_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          active_d1 <= 1'b0;
        else if (core_start) active_d1 <= 1'b0;
        else                 active_d1 <= active;
    end

    assign weight_vld = active_d1 && !rom_wait;

endmodule
