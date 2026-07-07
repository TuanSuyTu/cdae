`timescale 1ns/1ps

module cdae_sequencer_fsm (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start_inference,
    output reg         done_inference,

    output reg [4:0]   layer_idx,
    output reg         core_start,
    input  wire        core_done,

    output reg [9:0]   cfg_ch,
    output reg [9:0]   cfg_f_num,
    output reg [9:0]   cfg_dim_h,
    output reg [9:0]   cfg_dim_w,

    output reg [3:0]   datapath_mode,

    output reg [20:0]  base_addr_rd_a,
    output reg [20:0]  base_addr_rd_b,
    output reg [20:0]  base_addr_wr
);

    localparam [3:0] M_CONV_RELU = 4'd0;
    localparam [3:0] M_CONV_ONLY = 4'd1;
    localparam [3:0] M_CONV1     = 4'd2;
    localparam [3:0] M_POOL      = 4'd3;
    localparam [3:0] M_UP_CONV   = 4'd4;
    localparam [3:0] M_SUB       = 4'd5;
    localparam [3:0] M_ADD_SIG   = 4'd6;
    localparam [3:0] M_ADD_RELU  = 4'd7;

    localparam ST_IDLE       = 5'd0;
    localparam ST_E1         = 5'd1;
    localparam ST_E1_POOL    = 5'd2;
    localparam ST_E2         = 5'd3;
    localparam ST_E2_POOL    = 5'd4;
    localparam ST_BOT1_C1    = 5'd5;
    localparam ST_BOT1_C2    = 5'd6;
    localparam ST_BOT1_SH    = 5'd7;
    localparam ST_BOT1_ADD   = 5'd8;
    localparam ST_BOT2_C1    = 5'd9;
    localparam ST_BOT2_C2    = 5'd10;
    localparam ST_BOT2_ADD   = 5'd11;
    localparam ST_D1_UP      = 5'd12;
    localparam ST_D2_UP      = 5'd13;
    localparam ST_NOISE_C1   = 5'd14;
    localparam ST_NOISE_C2   = 5'd15;
    localparam ST_DENOISE    = 5'd16;
    localparam ST_R_C1       = 5'd17;
    localparam ST_R_C2       = 5'd18;
    localparam ST_FINAL      = 5'd19;
    localparam ST_DONE       = 5'd31;

    localparam [20:0] ADDR_INP   = 21'd0;
    localparam [20:0] ADDR_BUF_A = 21'd10000;
    localparam [20:0] ADDR_BUF_B = 21'd61000;
    localparam [20:0] ADDR_BUF_C = 21'd112000;
    localparam [20:0] ADDR_OUT   = 21'd122000;

    reg [4:0] state, next_state;

    // ==========================================================
    // State Register
    // Purpose:
    //   Luu tru trang thai hien tai cua FSM.
    // ==========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= ST_IDLE;
        else
            state <= next_state;
    end

    // ==========================================================
    // Block: Core Handshake Logic
    // Purpose:
    //   Giao tiep voi cac module tinh toan. Khi bat dau 1 state,
    //   kich hoat 'core_start' va cho den khi 'core_done' bat len.
    // ==========================================================
    reg wait_done;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wait_done  <= 1'b0;
            core_start <= 1'b0;
            layer_idx  <= 5'd0;
        end else begin
            if (state != ST_IDLE && state != ST_DONE && !wait_done) begin
                core_start <= 1'b1;
                wait_done  <= 1'b1;
                layer_idx  <= state;
            end else if (wait_done && core_start) begin
                core_start <= 1'b0;
            end else if (wait_done && core_done) begin
                wait_done <= 1'b0;
            end
        end
    end

    // ==========================================================
    // State Transition Logic
    // Purpose:
    //   Duyet qua 20 trang thai tuong ung voi 20 layer cua mang.
    //   Moi lan 'core_done' bat len (tu module tinh toan), FSM 
    //   se tu dong chuyen sang layer tiep theo.
    // ==========================================================
    always @(*) begin
        next_state = state; // Default: giu nguyen
        if (state == ST_IDLE && start_inference) begin
            next_state = ST_E1;
        end else if (wait_done && core_done && !core_start) begin
            case (state)
                ST_E1:       next_state = ST_E1_POOL;
                ST_E1_POOL:  next_state = ST_E2;
                ST_E2:       next_state = ST_E2_POOL;
                ST_E2_POOL:  next_state = ST_BOT1_C1;
                ST_BOT1_C1:  next_state = ST_BOT1_C2;
                ST_BOT1_C2:  next_state = ST_BOT1_SH;
                ST_BOT1_SH:  next_state = ST_BOT1_ADD;
                ST_BOT1_ADD: next_state = ST_BOT2_C1;
                ST_BOT2_C1:  next_state = ST_BOT2_C2;
                ST_BOT2_C2:  next_state = ST_BOT2_ADD;
                ST_BOT2_ADD: next_state = ST_D1_UP;
                ST_D1_UP:    next_state = ST_D2_UP;
                ST_D2_UP:    next_state = ST_NOISE_C1;
                ST_NOISE_C1: next_state = ST_NOISE_C2;
                ST_NOISE_C2: next_state = ST_DENOISE;
                ST_DENOISE:  next_state = ST_R_C1;
                ST_R_C1:     next_state = ST_R_C2;
                ST_R_C2:     next_state = ST_FINAL;
                ST_FINAL:    next_state = ST_DONE;
                default:     next_state = ST_IDLE;
            endcase
        end
        else if (state == ST_DONE && !start_inference)
            next_state = ST_IDLE;
    end

    // ==========================================================
    // Configuration Dispatcher
    // Purpose:
    //   Xuat cau hinh phan cung (so channel, kich thuoc anh, che do
    //   datapath_mode va dia chi RAM) xuong cho Data Path dua tren 
    //   trang thai hien tai.
    // ==========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_ch         <= 10'd0;
            cfg_f_num      <= 10'd0;
            cfg_dim_h      <= 10'd0;
            cfg_dim_w      <= 10'd0;
            datapath_mode  <= M_CONV_RELU;
            base_addr_rd_a <= 21'd0; base_addr_rd_b <= 21'd0;
            base_addr_rd_b <= 21'd0;
            base_addr_wr   <= 21'd0;
            done_inference <= 1'b0;
        end else begin
            done_inference <= (state == ST_DONE);

            case (next_state)

                ST_E1: begin
                    datapath_mode  <= M_CONV_RELU;
                    cfg_ch <= 10'd3; cfg_f_num <= 10'd16;
                    cfg_dim_h <= 10'd56; cfg_dim_w <= 10'd56;
                    base_addr_rd_a <= ADDR_INP; base_addr_rd_b <= ADDR_INP;
                    base_addr_wr   <= ADDR_BUF_A;
                end
                ST_E1_POOL: begin
                    datapath_mode  <= M_POOL;
                    cfg_ch <= 10'd16; cfg_dim_h <= 10'd56; cfg_dim_w <= 10'd56;
                    cfg_f_num <= 10'd0;
                    base_addr_rd_a <= ADDR_BUF_A; base_addr_rd_b <= ADDR_BUF_A;
                    base_addr_wr   <= ADDR_BUF_B;
                end
                ST_E2: begin
                    datapath_mode  <= M_CONV_RELU;
                    cfg_ch <= 10'd16; cfg_f_num <= 10'd32;
                    cfg_dim_h <= 10'd28; cfg_dim_w <= 10'd28;
                    base_addr_rd_a <= ADDR_BUF_B; base_addr_rd_b <= ADDR_BUF_B;
                    base_addr_wr   <= ADDR_BUF_A;
                end
                ST_E2_POOL: begin
                    datapath_mode  <= M_POOL;
                    cfg_ch <= 10'd32; cfg_dim_h <= 10'd28; cfg_dim_w <= 10'd28;
                    cfg_f_num <= 10'd0;
                    base_addr_rd_a <= ADDR_BUF_A; base_addr_rd_b <= ADDR_BUF_A;
                    base_addr_wr   <= ADDR_BUF_B;
                end

                ST_BOT1_C1: begin
                    datapath_mode  <= M_CONV_RELU;
                    cfg_ch <= 10'd32; cfg_f_num <= 10'd40;
                    cfg_dim_h <= 10'd14; cfg_dim_w <= 10'd14;
                    base_addr_rd_a <= ADDR_BUF_B; base_addr_rd_b <= ADDR_BUF_B;
                    base_addr_wr   <= ADDR_BUF_A;
                end
                ST_BOT1_C2: begin
                    datapath_mode  <= M_CONV_ONLY;
                    cfg_ch <= 10'd40; cfg_f_num <= 10'd40;
                    cfg_dim_h <= 10'd14; cfg_dim_w <= 10'd14;
                    base_addr_rd_a <= ADDR_BUF_A; base_addr_rd_b <= ADDR_BUF_A;
                    base_addr_wr   <= ADDR_BUF_C;
                end
                ST_BOT1_SH: begin
                    datapath_mode  <= M_CONV1;
                    cfg_ch <= 10'd32; cfg_f_num <= 10'd40;
                    cfg_dim_h <= 10'd14; cfg_dim_w <= 10'd14;
                    base_addr_rd_a <= ADDR_BUF_B; base_addr_rd_b <= ADDR_BUF_B;
                    base_addr_wr   <= ADDR_BUF_A;
                end
                ST_BOT1_ADD: begin
                    datapath_mode  <= M_ADD_RELU;
                    cfg_ch <= 10'd40;
                    cfg_dim_h <= 10'd14; cfg_dim_w <= 10'd14;
                    cfg_f_num <= 10'd0;
                    base_addr_rd_a <= ADDR_BUF_C; base_addr_rd_b <= ADDR_BUF_C;
                    base_addr_rd_b <= ADDR_BUF_A;
                    base_addr_wr   <= ADDR_BUF_B;
                end

                ST_BOT2_C1: begin
                    datapath_mode  <= M_CONV_RELU;
                    cfg_ch <= 10'd40; cfg_f_num <= 10'd40;
                    cfg_dim_h <= 10'd14; cfg_dim_w <= 10'd14;
                    base_addr_rd_a <= ADDR_BUF_B; base_addr_rd_b <= ADDR_BUF_B;
                    base_addr_wr   <= ADDR_BUF_A;
                end
                ST_BOT2_C2: begin
                    datapath_mode  <= M_CONV_ONLY;
                    cfg_ch <= 10'd40; cfg_f_num <= 10'd40;
                    cfg_dim_h <= 10'd14; cfg_dim_w <= 10'd14;
                    base_addr_rd_a <= ADDR_BUF_A; base_addr_rd_b <= ADDR_BUF_A;
                    base_addr_wr   <= ADDR_BUF_C;
                end
                ST_BOT2_ADD: begin
                    datapath_mode  <= M_ADD_RELU;
                    cfg_ch <= 10'd40;
                    cfg_dim_h <= 10'd14; cfg_dim_w <= 10'd14;
                    cfg_f_num <= 10'd0;
                    base_addr_rd_a <= ADDR_BUF_C; base_addr_rd_b <= ADDR_BUF_C;
                    base_addr_rd_b <= ADDR_BUF_B;
                    base_addr_wr   <= ADDR_BUF_A;
                end

                ST_D1_UP: begin
                    datapath_mode  <= M_UP_CONV;
                    cfg_ch <= 10'd40; cfg_f_num <= 10'd32;
                    cfg_dim_h <= 10'd28; cfg_dim_w <= 10'd28;
                    base_addr_rd_a <= ADDR_BUF_A; base_addr_rd_b <= ADDR_BUF_A;
                    base_addr_wr   <= ADDR_BUF_B;
                end
                ST_D2_UP: begin
                    datapath_mode  <= M_UP_CONV;
                    cfg_ch <= 10'd32; cfg_f_num <= 10'd16;
                    cfg_dim_h <= 10'd56; cfg_dim_w <= 10'd56;
                    base_addr_rd_a <= ADDR_BUF_B; base_addr_rd_b <= ADDR_BUF_B;
                    base_addr_wr   <= ADDR_BUF_A;
                end

                ST_NOISE_C1: begin
                    datapath_mode  <= M_CONV_ONLY;
                    cfg_ch <= 10'd16; cfg_f_num <= 10'd16;
                    cfg_dim_h <= 10'd56; cfg_dim_w <= 10'd56;
                    base_addr_rd_a <= ADDR_BUF_A; base_addr_rd_b <= ADDR_BUF_A;
                    base_addr_wr   <= ADDR_BUF_B;
                end
                ST_NOISE_C2: begin
                    datapath_mode  <= M_CONV_ONLY;
                    cfg_ch <= 10'd16; cfg_f_num <= 10'd3;
                    cfg_dim_h <= 10'd56; cfg_dim_w <= 10'd56;
                    base_addr_rd_a <= ADDR_BUF_B; base_addr_rd_b <= ADDR_BUF_B;
                    base_addr_wr   <= ADDR_BUF_A;
                end

                ST_DENOISE: begin
                    datapath_mode  <= M_SUB;
                    cfg_ch <= 10'd3;
                    cfg_dim_h <= 10'd56; cfg_dim_w <= 10'd56;
                    cfg_f_num <= 10'd0;
                    base_addr_rd_a <= ADDR_INP; base_addr_rd_b <= ADDR_INP;
                    base_addr_rd_b <= ADDR_BUF_A;
                    base_addr_wr   <= ADDR_BUF_B;
                end

                ST_R_C1: begin
                    datapath_mode  <= M_CONV_ONLY;
                    cfg_ch <= 10'd3; cfg_f_num <= 10'd12;
                    cfg_dim_h <= 10'd56; cfg_dim_w <= 10'd56;
                    base_addr_rd_a <= ADDR_BUF_B; base_addr_rd_b <= ADDR_BUF_B;
                    base_addr_wr   <= ADDR_BUF_A;
                end
                ST_R_C2: begin
                    datapath_mode  <= M_CONV_ONLY;
                    cfg_ch <= 10'd12; cfg_f_num <= 10'd3;
                    cfg_dim_h <= 10'd56; cfg_dim_w <= 10'd56;
                    base_addr_rd_a <= ADDR_BUF_A; base_addr_rd_b <= ADDR_BUF_A;
                    base_addr_wr   <= ADDR_BUF_C;
                end

                ST_FINAL: begin
                    datapath_mode  <= M_ADD_SIG;
                    cfg_ch <= 10'd3;
                    cfg_dim_h <= 10'd56; cfg_dim_w <= 10'd56;
                    cfg_f_num <= 10'd0;
                    base_addr_rd_a <= ADDR_BUF_B; base_addr_rd_b <= ADDR_BUF_B;
                    base_addr_rd_b <= ADDR_BUF_C;
                    base_addr_wr   <= ADDR_OUT;
                end

                default: begin

                end
            endcase
        end
    end
endmodule
