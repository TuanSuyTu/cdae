`timescale 1ns/1ps

// ==========================================================
// Module: Max Pooling 2x2 Engine
// Purpose:
//   Giam kich thuoc anh di mot nua (Downsampling).
//   So sanh 4 pixel trong cua so 2x2 va lay gia tri lon nhat.
//   Dung Line Buffer de luu pixel hang tren cho frame tiep theo.
// ==========================================================
module maxpool2x2 #(
    parameter int MAX_W  = 58,
    parameter int DATA_W = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire [9:0]               cfg_dim_h,
    input  wire [9:0]               cfg_dim_w,
    input  wire [9:0]               cfg_ch,

    input  wire                     start,
    output reg                      done,

    input  wire signed [DATA_W-1:0] pixel_in,
    input  wire                     pixel_vld,
    output wire                     pixel_rdy,

    output wire signed [DATA_W-1:0] pixel_out,
    output wire                     out_vld,
    input  wire                     out_rdy
);

    // ==========================================================
    // Block: Internal Declarations & Line Buffer
    // ==========================================================
    reg signed [DATA_W-1:0] prev_row [0:MAX_W-1];

    reg signed [DATA_W-1:0] out_reg;
    reg out_reg_vld;

    reg [9:0] row_cnt;
    reg [9:0] col_cnt;
    reg [9:0] ch_cnt;

    wire signed [DATA_W-1:0] max_tl, max_tr, max_bl, max_br;
    wire signed [DATA_W-1:0] max_top, max_bot, max_all;

    wire is_pool_pixel = row_cnt[0] && col_cnt[0];

    reg signed [DATA_W-1:0] left_pix;

    // ==========================================================
    // Block: Combinational Max Logic
    // Purpose: So sanh song song 4 gia tri max_tl, tr, bl, br.
    // ==========================================================
    assign max_tl  = prev_row[col_cnt - 10'd1];
    assign max_tr  = prev_row[col_cnt];
    assign max_bl  = left_pix;
    assign max_br  = pixel_in;
    assign max_top = (max_tl >= max_tr) ? max_tl : max_tr;
    assign max_bot = (max_bl >= max_br) ? max_bl : max_br;
    assign max_all = (max_top >= max_bot) ? max_top : max_bot;

    assign pixel_rdy = (~out_reg_vld) || out_rdy;
    assign out_vld   = out_reg_vld;
    assign pixel_out = out_reg;

    reg active;

    // ==========================================================
    // Block: Sequential FSM
    // Purpose: Quet anh va dieu khien viec cat vao Buffer / Tinh max.
    // ==========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_reg_vld <= 1'b0;
            out_reg     <= '0;
            left_pix    <= '0;
            row_cnt     <= 10'd0;
            col_cnt     <= 10'd0;
            ch_cnt      <= 10'd0;
            active      <= 1'b0;
            done        <= 1'b0;
        end
        else begin

            if (start) begin
                row_cnt     <= 10'd0;
                col_cnt     <= 10'd0;
                ch_cnt      <= 10'd0;
                active      <= 1'b1;
                done        <= 1'b0;
                out_reg_vld <= 1'b0;
            end
            else if (active && pixel_vld && pixel_rdy) begin

                if (row_cnt[0] == 1'b0) begin

                    prev_row[col_cnt] <= pixel_in;
                end

                left_pix <= pixel_in;

                if (is_pool_pixel) begin
                    out_reg     <= max_all;
                    out_reg_vld <= 1'b1;
                end
                else if (out_reg_vld && out_rdy) begin
                    out_reg_vld <= 1'b0;
                end

                if (col_cnt == cfg_dim_w - 10'd1) begin
                    col_cnt <= 10'd0;
                    if (row_cnt == cfg_dim_h - 10'd1) begin
                        row_cnt <= 10'd0;
                        if (ch_cnt == cfg_ch - 10'd1) begin

                            ch_cnt <= 10'd0;
                            active <= 1'b0;
                            done   <= 1'b1;
                        end
                        else begin
                            ch_cnt <= ch_cnt + 10'd1;
                        end
                    end
                    else begin
                        row_cnt <= row_cnt + 10'd1;
                    end
                end
                else begin
                    col_cnt <= col_cnt + 10'd1;
                end
            end
            else if (out_reg_vld && out_rdy) begin
                out_reg_vld <= 1'b0;
            end

            if (done && !start) begin
                done <= 1'b0;
            end
        end
    end

endmodule
