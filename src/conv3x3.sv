`timescale 1ns/1ps

module conv3x3 #(
    parameter WEIGHT_FRAC = 15,
    parameter PF = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output reg         idle,
    output reg         done,

    input  wire [9:0]  ch,
    input  wire [9:0]  dim_w,
    input  wire [9:0]  dim_h,
    input  wire [9:0]  f_num,

    input  wire signed [31:0] pixel_in,
    input  wire               pixel_vld,
    output wire               pixel_rdy,

    input  wire signed [PF*16-1:0] weight_in,
    input  wire                    weight_vld,
    output wire                    weight_rdy,

    input  wire signed [PF*16-1:0] bias_in,
    input  wire                    bias_vld,
    output wire                    bias_rdy,

    output wire signed [31:0] result_out,
    output wire               result_vld,
    input  wire               result_rdy
);

    localparam MAX_H = 58;
    localparam MAX_W = 58;
    localparam ACC_DEPTH = MAX_H * MAX_W;

    localparam S_IDLE       = 3'd0;
    localparam S_LOAD_FILT  = 3'd1;
    localparam S_CONV_RUN   = 3'd2;
    localparam S_DRAIN      = 3'd3;
    localparam S_STREAM_OUT = 3'd4;
    localparam S_STREAM_OUT_WAIT = 3'd5;

    reg [2:0] state;

    reg signed [15:0] filt [0:PF-1][0:8];
    reg signed [15:0] bias_reg [0:PF-1];
    reg               bias_loaded_q;
    reg [3:0]         w_cnt;

    (* ram_style = "ultra" *) reg [PF*48-1:0] acc_mem [0:ACC_DEPTH-1];

    reg [9:0] fi_cnt;
    reg [9:0] ci_cnt;
    reg [9:0] in_h;
    reg [9:0] in_w;

    reg signed [31:0] lb [0:2][0:MAX_W-1];
    reg [1:0] tp_mod3, md_mod3, bt_mod3;

    assign pixel_rdy  = (state == S_CONV_RUN);
    assign weight_rdy = (state == S_LOAD_FILT) && bias_loaded_q;
    assign bias_rdy   = (state == S_LOAD_FILT) && !bias_loaded_q;

    always @(posedge clk) begin
        if (state == S_CONV_RUN && pixel_vld && pixel_rdy) begin
            lb[bt_mod3][in_w] <= pixel_in;
        end
    end

    reg        fire_mac_s0;
    reg [9:0]  fire_comp_h;
    reg [9:0]  fire_comp_w;
    reg [1:0]  fire_tp_mod3;
    reg [1:0]  fire_md_mod3;
    reg [1:0]  fire_bt_mod3;

    reg signed [31:0] win_0, win_1, win_2, win_3, win_4, win_5, win_6, win_7, win_8;

    reg [11:0] str_addr_cnt;
    reg [9:0]  out_h, out_w;
    reg        done_issuing;
    reg        stream_vld;
    reg        stream_vld_d1;
    reg [4:0]  stream_fi_idx;
    reg [4:0]  stream_fi_idx_q;
    reg [4:0]  stream_fi_idx_d1;

    reg [11:0]        addr_s0;
    reg               vld_s0;

    reg signed [47:0] prod_s1 [0:PF-1][0:8];
    reg [11:0]        addr_s1;
    reg               vld_s1;



    reg signed [48:0] t_s2a [0:PF-1][0:3];
    reg signed [47:0] p8_s2a [0:PF-1];
    reg [11:0]        addr_s2a;
    reg               vld_s2a;

    reg signed [49:0] u_s2b [0:PF-1][0:1];
    reg signed [47:0] p8_s2b [0:PF-1];
    reg signed [63:0] base_acc_s2b [0:PF-1];
    reg [11:0]        addr_s2b;
    reg               vld_s2b;

    reg signed [51:0] mac_sum_s3 [0:PF-1];
    reg signed [63:0] base_acc_s3 [0:PF-1];
    reg [11:0]        addr_s3;
    reg               vld_s3;
    reg signed [63:0] new_acc_s3 [0:PF-1];

    reg [11:0] last_acc_addr;
    reg [9:0]  last_out_h;
    reg [9:0]  last_out_w;



    wire frame_compute_done = (vld_s3 && addr_s3 == last_acc_addr);
    wire out_stream_last = (out_h == last_out_h && out_w == last_out_w);

    reg stream_last_q;
    reg stream_last_d1;

    reg signed [31:0] skid_data;
    reg               skid_vld;
    reg               skid_last;

    reg signed [31:0] out_data_q;
    reg               out_vld_q;
    reg               out_last_q;

    assign result_out = out_data_q;
    assign result_vld = out_vld_q;

    wire can_issue = (state == S_STREAM_OUT) && (skid_vld + out_vld_q < 2'd2);
    wire        mux_rd_en   = (state == S_STREAM_OUT) ? (can_issue && !done_issuing && !stream_vld) : vld_s0;
    wire [11:0] mux_rd_addr = (state == S_STREAM_OUT) ? str_addr_cnt : addr_s0;

    wire [11:0] row_skip_offset = 12'd61 - {2'b0, dim_w[9:0]};

    function automatic signed [31:0] round_acc_to_q12;
        input signed [63:0] in_val;
        reg signed [63:0] rounded;
        begin
            rounded = (in_val + (64'sd1 << (WEIGHT_FRAC - 1))) >>> WEIGHT_FRAC;
            round_acc_to_q12 = rounded[31:0];
        end
    endfunction

    function automatic signed [31:0] sat32_from_i64(input signed [63:0] v);
        begin
            if (v > 64'sd2147483647) sat32_from_i64 = 32'sd2147483647;
            else if (v < -64'sd2147483648) sat32_from_i64 = -32'sd2147483648;
            else sat32_from_i64 = v[31:0];
        end
    endfunction

    reg [PF*48-1:0] acc_wr_data;
    always @(*) begin
        for (int i=0; i<PF; i=i+1) begin
             new_acc_s3[i] = base_acc_s3[i] + $signed({{12{mac_sum_s3[i][51]}}, mac_sum_s3[i]});
             acc_wr_data[i*48 +: 48] = new_acc_s3[i][47:0];
        end
    end

    reg [47:0] acc_read_val_arr [0:PF-1];
    reg signed [63:0] acc_rdata_s1 [0:PF-1];

    always @(posedge clk) begin
        if (mux_rd_en) begin
             for (int i=0; i<PF; i=i+1) acc_read_val_arr[i] <= acc_mem[mux_rd_addr][i*48 +: 48];
        end
        if (vld_s1) begin
             for (int i=0; i<PF; i=i+1) acc_rdata_s1[i] <= $signed({ {16{acc_read_val_arr[i][47]}}, acc_read_val_arr[i] });
        end
        if (vld_s3) begin
             acc_mem[addr_s3] <= acc_wr_data;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; idle <= 1'b1;
            out_vld_q <= 1'b0; skid_vld <= 1'b0; stream_vld <= 1'b0; stream_vld_d1 <= 1'b0;
            done_issuing <= 1'b0;
            vld_s0 <= 1'b0; vld_s1 <= 1'b0; vld_s2a <= 1'b0; vld_s2b <= 1'b0; vld_s3 <= 1'b0;
            bias_loaded_q <= 1'b0;
        end else begin
            idle <= (state == S_IDLE);

            case (state)
                S_IDLE: begin
                    if (start) begin
                         done <= 1'b0;
                         state <= S_LOAD_FILT; w_cnt <= 4'd0; bias_loaded_q <= 1'b0;
                         fi_cnt <= 10'd0; ci_cnt <= 10'd0; in_h <= 10'd0; in_w <= 10'd0;
                         last_acc_addr <= (dim_h - 10'd2) * 12'd58 + (dim_w - 10'd2);
                         last_out_h    <= dim_h - 10'd2;
                         last_out_w    <= dim_w - 10'd2;
                    end
                end

                S_LOAD_FILT: begin
                    tp_mod3 <= 2'd0; md_mod3 <= 2'd1; bt_mod3 <= 2'd2;
                    if (bias_vld && bias_rdy) begin
                        for (int i=0; i<PF; i=i+1) bias_reg[i] <= bias_in[i*16+:16];
                        bias_loaded_q <= 1'b1;
                    end
                    if (weight_vld && weight_rdy) begin
                        for (int i=0; i<PF; i=i+1) filt[i][w_cnt] <= weight_in[i*16+:16];
                        if (w_cnt == 4'd8) begin
                            w_cnt <= 4'd0; in_h <= 10'd0; in_w <= 10'd0; state <= S_CONV_RUN;
                        end else w_cnt <= w_cnt + 4'd1;
                    end
                end

                S_CONV_RUN: begin
                    if (pixel_vld && pixel_rdy) begin
                        if (in_w == dim_w - 10'd1) begin
                            in_w <= 10'd0;
                            tp_mod3 <= md_mod3; md_mod3 <= bt_mod3; bt_mod3 <= tp_mod3;
                            if (in_h == dim_h - 10'd1) begin
                                state <= S_DRAIN; in_h <= 10'd0;
                            end else in_h <= in_h + 10'd1;
                        end else in_w <= in_w + 10'd1;
                    end
                end

                S_DRAIN: begin
                    if (frame_compute_done) begin
                        if (ci_cnt < ch - 10'd1) begin
                            ci_cnt <= ci_cnt + 10'd1; in_h <= 10'd0; in_w <= 10'd0;
                            tp_mod3 <= 2'd0; md_mod3 <= 2'd1; bt_mod3 <= 2'd2;
                            state <= S_LOAD_FILT;
                        end else begin
                            state <= S_STREAM_OUT_WAIT;
                        end
                    end
                end

                S_STREAM_OUT_WAIT: begin
                    if (!result_rdy || !out_vld_q) begin
                        state <= S_STREAM_OUT;
                        out_h <= 10'd1; out_w <= 10'd1;
                        str_addr_cnt <= 12'd59;
                        done_issuing <= 1'b0; stream_vld <= 1'b0; out_vld_q <= 1'b0; skid_vld <= 1'b0;
                        stream_fi_idx <= 5'd0; stream_fi_idx_q <= 5'd0; stream_fi_idx_d1 <= 5'd0;
                    end
                end

                S_STREAM_OUT: begin
                     if (can_issue && !done_issuing && !stream_vld) begin
                         stream_vld <= 1'b1;
                         stream_last_q <= out_stream_last && (stream_fi_idx == PF[4:0] - 5'd1);
                         stream_fi_idx_q <= stream_fi_idx;

                         if (out_w == dim_w - 10'd2) begin
                             out_w <= 10'd1;
                             str_addr_cnt <= str_addr_cnt + row_skip_offset;
                             if (out_h == dim_h - 10'd2) begin
                                 if (stream_fi_idx == PF[4:0] - 5'd1) begin
                                     done_issuing <= 1'b1;
                                 end else begin
                                     stream_fi_idx <= stream_fi_idx + 5'd1;
                                     out_h <= 10'd1;
                                     out_w <= 10'd1;
                                     str_addr_cnt <= 12'd59;
                                 end
                             end else out_h <= out_h + 10'd1;
                         end else begin
                             out_w <= out_w + 10'd1;
                             str_addr_cnt <= str_addr_cnt + 12'd1;
                         end
                     end else stream_vld <= 1'b0;

                     stream_vld_d1 <= stream_vld;
                     stream_last_d1 <= stream_last_q;
                     stream_fi_idx_d1 <= stream_fi_idx_q;

                     if (stream_vld_d1) begin
                         if (out_vld_q && !result_rdy) begin
                              skid_data <= sat32_from_i64(round_acc_to_q12($signed({ {16{acc_read_val_arr[stream_fi_idx_d1][47]}}, acc_read_val_arr[stream_fi_idx_d1] })));
                              skid_vld  <= 1'b1;
                              skid_last <= stream_last_d1;
                         end else begin
                              out_data_q <= sat32_from_i64(round_acc_to_q12($signed({ {16{acc_read_val_arr[stream_fi_idx_d1][47]}}, acc_read_val_arr[stream_fi_idx_d1] })));
                              out_vld_q  <= 1'b1;
                              out_last_q <= stream_last_d1;
                         end
                     end else if (skid_vld && (!out_vld_q || result_rdy)) begin
                         out_data_q <= skid_data;
                         out_vld_q  <= 1'b1;
                         out_last_q <= skid_last;
                         skid_vld   <= 1'b0;
                     end else if (out_vld_q && result_rdy) begin
                         out_vld_q <= 1'b0;
                     end

                     if (out_vld_q && result_rdy && out_last_q && !stream_vld && !stream_vld_d1 && !skid_vld) begin
                         out_vld_q <= 1'b0; out_last_q <= 1'b0;
                         if (fi_cnt + PF[9:0] < {1'b0, f_num}) begin
                              fi_cnt <= fi_cnt + PF[9:0]; w_cnt <= 4'd0; ci_cnt <= 10'd0;
                              bias_loaded_q <= 1'b0; state <= S_LOAD_FILT;
                         end else begin
                              done <= 1'b1; state <= S_IDLE;
                         end
                     end
                end
                default: state <= S_IDLE;
            endcase

            if (state == S_CONV_RUN && pixel_vld && pixel_rdy && in_h >= 10'd2 && in_w >= 10'd2) begin
                fire_mac_s0 <= 1'b1; fire_comp_h <= in_h - 10'd1; fire_comp_w <= in_w - 10'd1;
                fire_tp_mod3 <= tp_mod3; fire_md_mod3 <= md_mod3; fire_bt_mod3 <= bt_mod3;
            end else fire_mac_s0 <= 1'b0;

              if (fire_mac_s0) begin
                  win_0 <= lb[fire_tp_mod3][fire_comp_w - 10'd1]; win_1 <= lb[fire_tp_mod3][fire_comp_w]; win_2 <= lb[fire_tp_mod3][fire_comp_w + 10'd1];
                  win_3 <= lb[fire_md_mod3][fire_comp_w - 10'd1]; win_4 <= lb[fire_md_mod3][fire_comp_w]; win_5 <= lb[fire_md_mod3][fire_comp_w + 10'd1];
                  win_6 <= lb[fire_bt_mod3][fire_comp_w - 10'd1]; win_7 <= lb[fire_bt_mod3][fire_comp_w]; win_8 <= lb[fire_bt_mod3][fire_comp_w + 10'd1];

                  addr_s0 <= {fire_comp_h[5:0], 6'b0} - {4'b0, fire_comp_h[5:0], 2'b0} - {5'b0, fire_comp_h[5:0], 1'b0} + {6'b0, fire_comp_w[5:0]};
                  vld_s0 <= 1'b1;
              end else vld_s0 <= 1'b0;

            if (vld_s0) begin
                for (int i=0; i<PF; i=i+1) begin
                    prod_s1[i][0] <= $signed(win_0) * $signed(filt[i][0]); prod_s1[i][1] <= $signed(win_1) * $signed(filt[i][1]); prod_s1[i][2] <= $signed(win_2) * $signed(filt[i][2]);
                    prod_s1[i][3] <= $signed(win_3) * $signed(filt[i][3]); prod_s1[i][4] <= $signed(win_4) * $signed(filt[i][4]); prod_s1[i][5] <= $signed(win_5) * $signed(filt[i][5]);
                    prod_s1[i][6] <= $signed(win_6) * $signed(filt[i][6]); prod_s1[i][7] <= $signed(win_7) * $signed(filt[i][7]); prod_s1[i][8] <= $signed(win_8) * $signed(filt[i][8]);
                end
                addr_s1 <= addr_s0;
                vld_s1  <= 1'b1;
            end else vld_s1  <= 1'b0;

            if (vld_s1) begin
                for (int i=0; i<PF; i=i+1) begin
                    t_s2a[i][0] <= $signed(prod_s1[i][0]) + $signed(prod_s1[i][1]); t_s2a[i][1] <= $signed(prod_s1[i][2]) + $signed(prod_s1[i][3]);
                    t_s2a[i][2] <= $signed(prod_s1[i][4]) + $signed(prod_s1[i][5]); t_s2a[i][3] <= $signed(prod_s1[i][6]) + $signed(prod_s1[i][7]);
                    p8_s2a[i]   <= prod_s1[i][8];
                end
                addr_s2a <= addr_s1;
                vld_s2a  <= 1'b1;
            end else vld_s2a  <= 1'b0;

            if (vld_s2a) begin
                for (int i=0; i<PF; i=i+1) begin
                    u_s2b[i][0] <= $signed(t_s2a[i][0]) + $signed(t_s2a[i][1]); u_s2b[i][1] <= $signed(t_s2a[i][2]) + $signed(t_s2a[i][3]);
                    p8_s2b[i]   <= p8_s2a[i];
                    base_acc_s2b[i] <= (ci_cnt == 10'd0) ? {{48{bias_reg[i][15]}}, bias_reg[i]} << 12 : acc_rdata_s1[i];
                end
                addr_s2b <= addr_s2a;
                vld_s2b  <= 1'b1;
            end else vld_s2b  <= 1'b0;

            if (vld_s2b) begin
                for (int i=0; i<PF; i=i+1) begin
                    mac_sum_s3[i] <= $signed({{2{u_s2b[i][0][49]}}, u_s2b[i][0]}) + $signed({{2{u_s2b[i][1][49]}}, u_s2b[i][1]}) + $signed({{4{p8_s2b[i][47]}}, p8_s2b[i]});
                    base_acc_s3[i] <= base_acc_s2b[i];
                end
                addr_s3 <= addr_s2b;
                vld_s3  <= 1'b1;
            end else vld_s3  <= 1'b0;
        end
    end
endmodule
