`timescale 1ns/1ps

module conv1x1 #(
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
    input  wire        is_first_row,
    input  wire        is_last_row,
    input  wire        is_first_col,
    input  wire        is_last_col,

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
    input  wire               result_rdy,
    output wire               addr_reset
);

    localparam MAX_H = 58;
    localparam MAX_W = 58;
    localparam ACC_DEPTH = MAX_H * MAX_W;

    localparam S_IDLE       = 3'd0;
    localparam S_LOAD_FILT  = 3'd1;
    localparam S_CONV_RUN   = 3'd2;
    localparam S_DRAIN      = 3'd3;
    localparam S_STREAM_OUT = 3'd4;

    reg [2:0] state;

    reg signed [15:0] filt [0:PF-1];
    reg signed [15:0] bias_reg [0:PF-1];
    reg               bias_loaded_q;

    (* ram_style = "ultra" *) reg [PF*48-1:0] acc_mem [0:ACC_DEPTH-1];

    reg [9:0] fi_cnt;
    reg [9:0] ci_cnt;
    reg [9:0] in_h;
    reg [9:0] in_w;
    reg [9:0] out_h;
    reg [9:0] out_w;

    reg       out_vld_q;
    reg signed [31:0] out_data_q;

    wire cfg_oob = (dim_h > MAX_H[9:0]) || (dim_w > MAX_W[9:0]) || (dim_h < 10'd1) || (dim_w < 10'd1);
    reg addr_reset_q;

    assign weight_rdy = (state == S_LOAD_FILT) &&  bias_loaded_q;
    assign bias_rdy   = (state == S_LOAD_FILT) && !bias_loaded_q;
    assign pixel_rdy  = (state == S_CONV_RUN)  && !cfg_oob;
    assign result_vld = out_vld_q;
    assign result_out = out_data_q;
    assign addr_reset = addr_reset_q;

    reg signed [31:0] p_in_s0;
    reg               vld_s0;

    reg signed [47:0] prod_s1 [0:PF-1];
    reg [11:0]        addr_s0;
    reg [11:0]        addr_s1;
    reg               vld_s1;


    reg signed [63:0] base_acc_s2 [0:PF-1];
    reg signed [47:0] prod_s2 [0:PF-1];
    reg [11:0]        addr_s2;
    reg               vld_s2;

    reg [11:0]        addr_s3;
    reg               vld_s3;
    reg signed [63:0] new_acc_s3 [0:PF-1];

    reg [11:0] last_acc_addr;
    wire frame_compute_done = vld_s3 && (addr_s3 == last_acc_addr);
    wire out_stream_last = (out_h == dim_h - 10'd1) && (out_w == dim_w - 10'd1);

    reg               stream_vld;
    reg               stream_vld_d1;
    reg               stream_last_q;
    reg               stream_last_d1;
    reg signed [31:0] skid_data;
    reg               skid_vld;
    reg               skid_last;
    reg               out_last_q;
    reg               done_issuing;
    reg [11:0]        str_addr_cnt;
    
    reg [4:0]         stream_fi_idx;
    reg [4:0]         stream_fi_idx_q;
    reg [4:0]         stream_fi_idx_d1;

    wire [11:0] row_skip_offset = 12'd59 - {2'b0, dim_w[9:0]};

    wire [2:0] slots_used = (out_vld_q && !result_rdy) + skid_vld + stream_vld + stream_vld_d1;
    wire can_issue = (state == S_STREAM_OUT) && (slots_used < 3'd3);

    wire [11:0] mux_rd_addr = (state == S_STREAM_OUT) ? str_addr_cnt : addr_s0;
    wire        mux_rd_en   = (state == S_STREAM_OUT) ? (can_issue && !done_issuing && !stream_vld) : vld_s0;

    reg [PF*48-1:0] acc_wr_data;
    always @(*) begin
        for (int i=0; i<PF; i=i+1) acc_wr_data[i*48 +: 48] = new_acc_s3[i][47:0];
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

    function automatic signed [31:0] sat32_from_i64;
        input signed [63:0] in_val;
        begin
            if (in_val > 64'sd2147483647) sat32_from_i64 = 32'sh7fffffff;
            else if (in_val < -64'sd2147483648) sat32_from_i64 = 32'sh80000000;
            else sat32_from_i64 = in_val[31:0];
        end
    endfunction

    function automatic signed [31:0] round_acc_to_q12;
        input signed [63:0] in_val;
        reg signed [63:0] rounded;
        begin
            rounded = (in_val + (64'sd1 << (WEIGHT_FRAC - 1))) >>> WEIGHT_FRAC;
            round_acc_to_q12 = rounded[31:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vld_s0 <= 1'b0; vld_s1 <= 1'b0; vld_s2 <= 1'b0; vld_s3 <= 1'b0;
            stream_vld <= 1'b0; stream_vld_d1 <= 1'b0; stream_last_q <= 1'b0; stream_last_d1 <= 1'b0;
            skid_vld <= 1'b0; skid_last <= 1'b0; out_last_q <= 1'b0;
            done_issuing <= 1'b0; out_vld_q <= 1'b0; out_data_q <= 16'sd0; str_addr_cnt <= 12'd0;
            fi_cnt <= 10'd0; ci_cnt <= 10'd0;
            in_h <= 10'd0; in_w <= 10'd0; out_h <= 10'd0; out_w <= 10'd0;
            state <= S_IDLE; idle <= 1'b1; done <= 1'b0; bias_loaded_q <= 1'b0;
            last_acc_addr <= 12'd0; addr_reset_q <= 1'b0;
            stream_fi_idx <= 5'd0; stream_fi_idx_q <= 5'd0; stream_fi_idx_d1 <= 5'd0;
        end else begin
            idle <= (state == S_IDLE);
            if (state == S_IDLE) done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                         if (cfg_oob) done <= 1'b1;
                         else begin
                                state <= S_LOAD_FILT; bias_loaded_q <= 1'b0;
                                fi_cnt <= 10'd0; ci_cnt <= 10'd0; in_h <= 10'd0; in_w <= 10'd0;
                                last_acc_addr <= (dim_h - 10'd1) * 12'd58 + (dim_w - 10'd1);
                                addr_reset_q <= 1'b1; stream_fi_idx <= 5'd0;
                         end
                    end
                end

                S_LOAD_FILT: begin
                    addr_reset_q <= 1'b0;
                    if (bias_vld && bias_rdy) begin
                        for (int i=0; i<PF; i=i+1) bias_reg[i] <= bias_in[i*16 +: 16];
                        bias_loaded_q <= 1'b1;
                    end
                    if (weight_vld && weight_rdy) begin
                        for (int i=0; i<PF; i=i+1) filt[i] <= weight_in[i*16 +: 16];
                        state <= S_CONV_RUN; in_h <= 10'd0; in_w <= 10'd0;
                    end
                end

                S_CONV_RUN: begin
                    if (pixel_vld && pixel_rdy) begin
                        if (in_w == dim_w - 10'd1) begin
                            in_w <= 10'd0;
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
                            state <= S_LOAD_FILT;
                        end else begin
                            state <= S_STREAM_OUT;
                            out_h <= 10'd0; out_w <= 10'd0;
                            str_addr_cnt <= 12'd0;
                            done_issuing <= 1'b0; stream_vld <= 1'b0; out_vld_q <= 1'b0; skid_vld <= 1'b0;
                            stream_fi_idx <= 5'd0; addr_reset_q <= 1'b0;
                        end
                    end
                end

                S_STREAM_OUT: begin
                     if (can_issue && !done_issuing && !stream_vld) begin
                         stream_vld <= 1'b1;
                         stream_last_q <= out_stream_last && (stream_fi_idx == PF[4:0] - 5'd1);
                         stream_fi_idx_q <= stream_fi_idx;

                         if (out_w == dim_w - 10'd1) begin
                             out_w <= 10'd0;
                             str_addr_cnt <= str_addr_cnt + row_skip_offset;
                             if (out_h == dim_h - 10'd1) begin
                                 if (stream_fi_idx == PF[4:0] - 5'd1) begin
                                     done_issuing <= 1'b1;
                                 end else begin
                                     stream_fi_idx <= stream_fi_idx + 5'd1;
                                     out_h <= 10'd0;
                                     out_w <= 10'd0;
                                     str_addr_cnt <= 12'd0;
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
                         if (fi_cnt + PF[9:0] < f_num) begin
                              fi_cnt <= fi_cnt + PF[9:0]; ci_cnt <= 10'd0;
                              bias_loaded_q <= 1'b0; state <= S_LOAD_FILT; addr_reset_q <= 1'b1;
                         end else begin
                              done <= 1'b1; state <= S_IDLE;
                         end
                     end
                end
                default: state <= S_IDLE;
            endcase

            if (state == S_CONV_RUN && pixel_vld && pixel_rdy) begin
                p_in_s0 <= pixel_in;
                addr_s0 <= {in_h[5:0], 6'b0} - {4'b0, in_h[5:0], 2'b0} - {5'b0, in_h[5:0], 1'b0} + {6'b0, in_w[5:0]};
                vld_s0 <= 1'b1;
            end else vld_s0 <= 1'b0;

            if (vld_s0) begin
                for (int i=0; i<PF; i=i+1) prod_s1[i] <= $signed(p_in_s0) * $signed(filt[i]);
                addr_s1 <= addr_s0;
                vld_s1  <= 1'b1;
            end else vld_s1  <= 1'b0;

            if (vld_s1) begin
                for (int i=0; i<PF; i=i+1) begin
                    prod_s2[i] <= prod_s1[i];
                end
                addr_s2 <= addr_s1;
                vld_s2  <= 1'b1;
            end else vld_s2  <= 1'b0;

            if (vld_s2) begin
                for (int i=0; i<PF; i=i+1) begin
                    reg signed [63:0] base_val;
                    base_val = (ci_cnt == 10'd0) ? {{48{bias_reg[i][15]}}, bias_reg[i]} << 12 : acc_rdata_s1[i];
                    new_acc_s3[i] <= base_val + {{16{prod_s2[i][47]}}, prod_s2[i]};
                end
                addr_s3 <= addr_s2;
                vld_s3  <= 1'b1;
            end else vld_s3  <= 1'b0;
        end
    end
endmodule
