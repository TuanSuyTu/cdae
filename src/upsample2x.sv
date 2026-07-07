`timescale 1ns/1ps

// ==========================================================
// Module: Upsampling 2x (Nearest Neighbor)
// Purpose:
//   Tang kich thuoc anh gap doi (Upsampling).
//   Moi pixel dau vao se duoc nhan ban thanh 1 khoi 2x2.
//   Dung trong cac lop Decoder de khoi phuc do phan giai.
// ==========================================================
module upsample2x #(
    parameter int MAX_W  = 58,
    parameter int DATA_W = 32
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire [9:0]                cfg_dim_h,
    input  wire [9:0]                cfg_dim_w,
    input  wire [9:0]                cfg_ch,

    input  wire                      start,
    output reg                       done,

    input  wire signed [DATA_W-1:0]  pixel_in,
    input  wire                      pixel_vld,
    output wire                      pixel_rdy,

    output wire signed [DATA_W-1:0]  pixel_out,
    output wire                      out_vld,
    input  wire                      out_rdy
);

    // ==========================================================
    // Block: Internal Declarations & Line Buffer
    // ==========================================================
    reg signed [DATA_W-1:0] row_buf [0:MAX_W-1];
    reg signed [DATA_W-1:0] out_reg;
    reg signed [DATA_W-1:0] dup_pix;
    reg out_reg_vld;

    reg [9:0] ch_cnt;
    reg [9:0] row_cnt;
    reg [9:0] col_cnt;
    reg [9:0] replay_col;

    reg replay_mode;
    reg dup_phase;
    reg active;
    reg finishing;

    assign pixel_rdy = ((~out_reg_vld) || out_rdy) && (~replay_mode) && (~dup_phase) && active;
    assign out_vld   = out_reg_vld;
    assign pixel_out = out_reg;

    // ==========================================================
    // Block: Sequential FSM
    // Purpose: Dieu khien nhan ban diem anh chieu doc / ngang.
    // ==========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_reg_vld <= 1'b0;
            out_reg     <= '0;
            dup_pix     <= '0;
            ch_cnt      <= 10'd0;
            row_cnt     <= 10'd0;
            col_cnt     <= 10'd0;
            replay_col  <= 10'd0;
            replay_mode <= 1'b0;
            dup_phase   <= 1'b0;
            active      <= 1'b0;
            done        <= 1'b0;
            finishing    <= 1'b0;
        end
        else begin
            if (start) begin
                ch_cnt      <= 10'd0;
                row_cnt     <= 10'd0;
                col_cnt     <= 10'd0;
                replay_col  <= 10'd0;
                replay_mode <= 1'b0;
                dup_phase   <= 1'b0;
                active      <= 1'b1;
                done        <= 1'b0;
                finishing    <= 1'b0;
                out_reg_vld <= 1'b0;
            end
            else if (active) begin
                if (out_reg_vld && !out_rdy) begin

                end
                else begin
                    out_reg_vld <= 1'b0;

                    if (!replay_mode) begin

                        if (!dup_phase) begin
                            if (pixel_vld && pixel_rdy) begin
                                row_buf[col_cnt] <= pixel_in;
                                dup_pix     <= pixel_in;
                                out_reg     <= pixel_in;
                                out_reg_vld <= 1'b1;
                                dup_phase   <= 1'b1;
                            end
                        end
                        else begin
                            out_reg     <= dup_pix;
                            out_reg_vld <= 1'b1;
                            dup_phase   <= 1'b0;

                            if (col_cnt == cfg_dim_w - 10'd1) begin
                                col_cnt     <= 10'd0;
                                replay_col  <= 10'd0;
                                replay_mode <= 1'b1;
                            end
                            else begin
                                col_cnt <= col_cnt + 10'd1;
                            end
                        end
                    end
                    else begin

                        if (!dup_phase) begin
                            dup_pix     <= row_buf[replay_col];
                            out_reg     <= row_buf[replay_col];
                            out_reg_vld <= 1'b1;
                            dup_phase   <= 1'b1;
                        end
                        else begin
                            out_reg     <= dup_pix;
                            out_reg_vld <= 1'b1;
                            dup_phase   <= 1'b0;

                            if (replay_col == cfg_dim_w - 10'd1) begin
                                replay_col  <= 10'd0;
                                replay_mode <= 1'b0;

                                if (row_cnt == cfg_dim_h - 10'd1) begin
                                    row_cnt <= 10'd0;
                                    if (ch_cnt == cfg_ch - 10'd1) begin

                                        ch_cnt    <= 10'd0;
                                        finishing <= 1'b1;
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
                                replay_col <= replay_col + 10'd1;
                            end
                        end
                    end
                end
            end

            if (finishing) begin
                finishing    <= 1'b0;
                active       <= 1'b0;
                done         <= 1'b1;
                out_reg_vld  <= 1'b0;
            end

            if (done && !start) begin
                done <= 1'b0;
            end
        end
    end

endmodule
