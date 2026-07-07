`timescale 1ns/1ps

// ==========================================================
// Module: Zero Padding Feeder
// Purpose:
//   Nhoi them pixel 0 vao vien cua anh (Padding) truoc khi 
//   day vao module conv3x3. Giup giu nguyen kich thuoc anh
//   khi thuc hien tich chap (Same Convolution).
// ==========================================================
module zero_pad_feeder #(
    parameter PF = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,

    input  wire [9:0]  dim_h,
    input  wire [9:0]  dim_w,
    input  wire [9:0]  ch,
    input  wire [9:0]  f_num,

    output wire signed [31:0] pixel_out,
    output wire               pixel_vld,
    input  wire               pixel_rdy,

    input  wire signed [31:0] ram_data,
    input  wire               ram_data_vld,

    output wire               ram_rd,
    output wire               addr_reset
);

    // ==========================================================
    // Block: Internal Declarations
    // ==========================================================
    wire [9:0] pad_h = dim_h + 10'd2;
    wire [9:0] pad_w = dim_w + 10'd2;

    reg [9:0] row, col;
    reg [9:0] ch_cnt, fi_cnt;
    reg       active;

    wire is_border = (row == 10'd0) || (row == pad_h - 10'd1) ||
                     (col == 10'd0) || (col == pad_w - 10'd1);

    // ==========================================================
    // Block: Combinational Datapath
    // Purpose: Kiem tra toa do de quyet dinh xuat 0 (vien) hay data.
    // ==========================================================
    assign pixel_out = is_border ? 32'sd0 : ram_data;

    assign pixel_vld = active && (is_border || ram_data_vld);

    wire handshake = pixel_vld && pixel_rdy;

    assign ram_rd    = active && !is_border && handshake;

    reg addr_reset_r;
    assign addr_reset = addr_reset_r;

    // ==========================================================
    // Block: Coordinate FSM
    // Purpose: Quet qua tung toa do (row, col) cua anh da padding.
    // ==========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row          <= 10'd0;
            col          <= 10'd0;
            ch_cnt       <= 10'd0;
            fi_cnt       <= 10'd0;
            active       <= 1'b0;
            addr_reset_r <= 1'b0;
        end else begin
            addr_reset_r <= 1'b0;

            if (start) begin
                row        <= 10'd0;
                col        <= 10'd0;
                ch_cnt     <= 10'd0;
                fi_cnt     <= 10'd0;
                active     <= 1'b1;
            end
            else if (active) begin

                if (handshake) begin

                    if (col == pad_w - 10'd1) begin
                        col <= 10'd0;
                        if (row == pad_h - 10'd1) begin
                            row <= 10'd0;

                            if (ch_cnt == ch - 10'd1) begin
                                ch_cnt <= 10'd0;
                                if (fi_cnt + PF[9:0] >= {1'b0, f_num}) begin
                                    active <= 1'b0;
                                end else begin
                                    fi_cnt       <= fi_cnt + PF[9:0];
                                    addr_reset_r <= 1'b1;
                                end
                            end else begin
                                ch_cnt <= ch_cnt + 10'd1;
                            end
                        end else begin
                            row <= row + 10'd1;
                        end
                    end else begin
                        col <= col + 10'd1;
                    end
                end
            end
        end
    end

endmodule
