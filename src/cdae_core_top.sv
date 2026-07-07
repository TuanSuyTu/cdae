`timescale 1ns/1ps

module cdae_core_top #(
    parameter PF = 16
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] ext_dina,
    input  wire [20:0] ext_addra,
    input  wire        ext_wea,
    output wire [15:0] ext_douta,

    input  wire        start_inference,
    output wire        done_inference
);

    wire [4:0]  layer_idx;
    wire        core_start;
    wire [3:0]  datapath_mode;
    wire [9:0]  cfg_ch, cfg_f_num, cfg_dim_h, cfg_dim_w;
    wire [20:0] base_rd_a, base_rd_b, base_wr;
    wire        core_done;

    // ==========================================================
    // Module: Sequencer FSM
    // Purpose:
    //   Dieu phien toan bo chu trinh suy luan (inference).
    //   Sinh ra datapath_mode va dia chi RAM de mach Crossbar biet
    //   can noi day tu RAM vao module tinh toan nao.
    // ==========================================================
    cdae_sequencer_fsm fsm_inst (
        .clk(clk), .rst_n(rst_n),
        .start_inference(start_inference),
        .done_inference(done_inference),
        .layer_idx(layer_idx),
        .core_start(core_start),
        .core_done(core_done),
        .cfg_ch(cfg_ch), .cfg_f_num(cfg_f_num),
        .cfg_dim_h(cfg_dim_h), .cfg_dim_w(cfg_dim_w),
        .datapath_mode(datapath_mode),
        .base_addr_rd_a(base_rd_a),
        .base_addr_rd_b(base_rd_b),
        .base_addr_wr(base_wr)
    );

    localparam [3:0] M_CONV_RELU = 4'd0;
    localparam [3:0] M_CONV_ONLY = 4'd1;
    localparam [3:0] M_CONV1     = 4'd2;
    localparam [3:0] M_POOL      = 4'd3;
    localparam [3:0] M_UP_CONV   = 4'd4;
    localparam [3:0] M_SUB       = 4'd5;
    localparam [3:0] M_ADD_SIG   = 4'd6;
    localparam [3:0] M_ADD_RELU  = 4'd7;

    wire elem_mode = (datapath_mode == M_SUB) ||
                     (datapath_mode == M_ADD_SIG) ||
                     (datapath_mode == M_ADD_RELU);


    wire pad_addr_reset;
    wire conv1_addr_reset;
    wire rd_a_handshake, wr_handshake;

    reg         ram_wea_r;
    reg  [31:0] ram_dina_r;
    wire [20:0] ram_addra;
    wire [31:0] ram_douta;

    reg inference_active;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)               inference_active <= 1'b0;
        else if (start_inference) inference_active <= 1'b1;
        else if (done_inference)  inference_active <= 1'b0;
    end
    reg core_done_r;

    reg layer_active;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           layer_active <= 1'b0;
        else if (core_start)  layer_active <= 1'b1;
        else if (core_done)   layer_active <= 1'b0;
    end

    // ==========================================================
    // Block: Time-Multiplexing 
    // Purpose:
    //   Tai su dung 1 cong doc cua RAM cho 2 ma tran. Phuc vu
    //   doc A va B tuan tu roi chot lai vao elem_a_latch,
    //   nham tiet kiem tai nguyen so voi viec dung Dual-Port.
    // ==========================================================
    reg elem_phase;
    reg signed [31:0] elem_a_latch;
    wire signed [31:0] elem_b_data;
    reg elem_b_valid;

    assign elem_b_data = ram_douta;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            elem_phase   <= 1'b0;
            elem_a_latch <= 32'sd0;
            elem_b_valid <= 1'b0;
        end else if (core_start) begin
            elem_phase   <= 1'b0;
            elem_a_latch <= 32'sd0;
            elem_b_valid <= 1'b0;
        end else if (elem_mode && layer_active) begin
            elem_phase <= ~elem_phase;
            if (elem_phase == 1'b1) begin

                elem_a_latch <= ram_douta;

                elem_b_valid <= 1'b1;
            end else begin

                elem_b_valid <= 1'b0;
            end
        end else begin
            elem_b_valid <= 1'b0;
            elem_phase   <= 1'b0;
        end
    end

    wire elem_data_ready = elem_b_valid;

    // ==========================================================
    // Block: Address Counters
    // Purpose:
    //   Tinh toan offset de quet qua tung
    //   pixel trong RAM. Dung chung offset cho ca doc va ghi.
    // ==========================================================
    reg [20:0] act_rd_offset_a, act_wr_offset;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_rd_offset_a <= 21'd0;
            act_wr_offset   <= 21'd0;
        end else if (core_start) begin
            act_rd_offset_a <= rd_a_handshake ? 21'd1 : 21'd0;
            act_wr_offset   <= wr_handshake   ? 21'd1 : 21'd0;
        end else begin
            if (pad_addr_reset || conv1_addr_reset) act_rd_offset_a <= 21'd0;
            else if (rd_a_handshake) act_rd_offset_a <= act_rd_offset_a + 21'd1;
            if (wr_handshake)   act_wr_offset   <= act_wr_offset + 21'd1;
        end
    end

    wire write_masked;

    wire [20:0] next_rd_offset_a = (core_start || pad_addr_reset || conv1_addr_reset) ? 21'd0 : act_rd_offset_a;
    wire [20:0] addr_a_normal = base_rd_a + next_rd_offset_a + (rd_a_handshake ? 21'd1 : 21'd0);
    wire [20:0] addr_b_via_a  = base_rd_b + next_rd_offset_a;
    assign ram_addra = (elem_mode && elem_phase) ? addr_b_via_a : addr_a_normal;

    // ==========================================================
    // Module: Unified RAM Pool
    // Purpose:
    //   Bo nho tap trung chua Weight, Input, Output va cac Buffer.
    //   Tu dong switch quyen dieu khien RAM cho he thong ngoai (PS)
    //   khi ranh roi hoac cho Core PL khi dang chay inference.
    // ==========================================================
    cdae_unified_ram ram_inst (
        .clk(clk),
        .ena(1'b1),
        .addra(inference_active ? ram_addra : ext_addra),
        .douta(ram_douta),
        .wec(inference_active ? (ram_wea_r && !core_start && write_masked) : ext_wea),
        .addrc(inference_active ? (base_wr + act_wr_offset) : ext_addra),
        .dinc(inference_active ? ram_dina_r : {{16{ext_dina[15]}}, ext_dina})
    );

    assign ext_douta = ram_douta[15:0];

    // ==========================================================
    // Block: Module Interconnections
    // Purpose:
    //   Khai bao he thong day dan (Wires) va thanh ghi (Regs)
    //   de noi MUX Crossbar voi cac module tinh toan phia duoi.
    //   Su dung chuan giao tiep Handshake (Valid-Ready).
    // ==========================================================
    wire signed [31:0] conv3_in_data;
    wire signed [31:0] conv3_out_data;
    wire        conv3_in_vld, conv3_in_rdy, conv3_out_vld;
    reg         conv3_out_rdy;
    wire        conv3_idle, conv3_done;
    wire        conv3_weight_rdy, conv3_bias_rdy;

    reg  signed [31:0] conv1_in_data;
    wire signed [31:0] conv1_out_data;
    reg         conv1_in_vld, conv1_out_rdy;
    wire        conv1_in_rdy, conv1_out_vld;
    wire        conv1_weight_rdy, conv1_bias_rdy;
    wire        conv1_idle, conv1_done;

    reg  signed [31:0] relu_in_data;
    wire signed [31:0] relu_out_data;
    reg         relu_in_vld, relu_out_rdy;
    wire        relu_in_rdy, relu_out_vld;

    reg  signed [31:0] pool_in_data;
    wire signed [31:0] pool_out_data;
    reg         pool_in_vld, pool_out_rdy;
    wire        pool_in_rdy, pool_out_vld;
    wire        pool_done;

    reg  signed [31:0] up_in_data;
    wire signed [31:0] up_out_data;
    reg         up_in_vld, up_out_rdy;
    wire        up_in_rdy, up_out_vld;
    wire        up_done;

    wire signed [31:0] add_out_data, sub_out_data, sig_out_data;
    reg  add_a_vld, add_b_vld, add_out_rdy;
    reg  sub_a_vld, sub_b_vld, sub_out_rdy;
    reg  sig_in_vld, sig_out_rdy;
    wire add_out_vld, add_a_rdy, add_b_rdy;
    wire sub_out_vld, sub_a_rdy, sub_b_rdy;
    wire sig_in_rdy, sig_out_vld;

    wire [16:0] w_rom_addr;
    wire [PF*16-1:0] w_rom_data, w_out;
    wire        w_vld, w_rdy;

    wire conv3_wb_rdy = conv3_weight_rdy || conv3_bias_rdy;
    wire conv1_wb_rdy = conv1_weight_rdy || conv1_bias_rdy;
    assign w_rdy = (datapath_mode == M_CONV1) ? conv1_wb_rdy : conv3_wb_rdy;

    weight_rom #(.PF(PF)) wrom_inst (.clk(clk), .addr(w_rom_addr), .dout(w_rom_data));

    weight_controller #(.PF(PF)) wctrl_inst (
        .clk(clk), .rst_n(rst_n),
        .layer_idx(layer_idx), .core_start(core_start),
        .rom_addr(w_rom_addr), .rom_data(w_rom_data),
        .weight_out(w_out), .weight_vld(w_vld), .weight_rdy(w_rdy)
    );

    wire conv3_modes = (datapath_mode == M_CONV_RELU) ||
                       (datapath_mode == M_CONV_ONLY) ||
                       (datapath_mode == M_UP_CONV);

    reg  signed [31:0] pad_src_data;
    reg                pad_src_vld;

    wire        pad_ram_rd;
    wire        pad_pixel_vld;
    wire signed [31:0] pad_pixel_out;

    wire pad_start = core_start && conv3_modes;

    wire [9:0] up_dim_h = cfg_dim_h >> 1;
    wire [9:0] up_dim_w = cfg_dim_w >> 1;

    zero_pad_feeder #(.PF(PF)) pad_inst (
        .clk(clk), .rst_n(rst_n),
        .start(pad_start),
        .dim_h(cfg_dim_h), .dim_w(cfg_dim_w),
        .ch(cfg_ch), .f_num(cfg_f_num),
        .pixel_out(pad_pixel_out),
        .pixel_vld(pad_pixel_vld),
        .pixel_rdy(conv3_in_rdy),
        .ram_data(pad_src_data),
        .ram_data_vld(pad_src_vld),
        .ram_rd(pad_ram_rd),
        .addr_reset(pad_addr_reset)
    );

    assign conv3_in_data = pad_pixel_out;
    assign conv3_in_vld  = pad_pixel_vld;

    wire [9:0] conv3_dim_h = cfg_dim_h + 10'd2;
    wire [9:0] conv3_dim_w = cfg_dim_w + 10'd2;

    wire conv3_start = core_start && conv3_modes;
    wire pool_start  = core_start && (datapath_mode == M_POOL);

    wire up_restart  = pad_addr_reset && (datapath_mode == M_UP_CONV);
    wire up_start    = (core_start && (datapath_mode == M_UP_CONV)) || up_restart;

    conv3x3 #(.PF(PF)) core_conv3 (
        .clk(clk), .rst_n(rst_n),
        .start(conv3_start), .idle(conv3_idle), .done(conv3_done),
        .ch(cfg_ch), .dim_w(conv3_dim_w), .dim_h(conv3_dim_h), .f_num(cfg_f_num),
        .pixel_in(conv3_in_data), .pixel_vld(conv3_in_vld), .pixel_rdy(conv3_in_rdy),
        .weight_in(w_out), .weight_vld(w_vld), .weight_rdy(conv3_weight_rdy),
        .bias_in(w_out),   .bias_vld(w_vld),   .bias_rdy(conv3_bias_rdy),
        .result_out(conv3_out_data), .result_vld(conv3_out_vld), .result_rdy(conv3_out_rdy)
    );

    conv1x1 #(.PF(PF)) core_conv1 (
        .clk(clk), .rst_n(rst_n),
        .start(core_start && (datapath_mode == M_CONV1)),
        .idle(conv1_idle), .done(conv1_done),
        .ch(cfg_ch), .dim_w(cfg_dim_w), .dim_h(cfg_dim_h), .f_num(cfg_f_num),
        .pixel_in(conv1_in_data), .pixel_vld(conv1_in_vld), .pixel_rdy(conv1_in_rdy),
        .weight_in(w_out), .weight_vld(w_vld), .weight_rdy(conv1_weight_rdy),
        .bias_in(w_out),   .bias_vld(w_vld),   .bias_rdy(conv1_bias_rdy),
        .result_out(conv1_out_data), .result_vld(conv1_out_vld), .result_rdy(conv1_out_rdy),
        .addr_reset(conv1_addr_reset)
    );

    relu core_relu (
        .clk(clk), .rst_n(rst_n),
        .pixel_in(relu_in_data), .pixel_vld(relu_in_vld), .pixel_rdy(relu_in_rdy),
        .pixel_out(relu_out_data), .out_vld(relu_out_vld), .out_rdy(relu_out_rdy)
    );

    maxpool2x2 core_pool (
        .clk(clk), .rst_n(rst_n),
        .cfg_dim_h(cfg_dim_h), .cfg_dim_w(cfg_dim_w), .cfg_ch(cfg_ch),
        .start(pool_start), .done(pool_done),
        .pixel_in(pool_in_data), .pixel_vld(pool_in_vld), .pixel_rdy(pool_in_rdy),
        .pixel_out(pool_out_data), .out_vld(pool_out_vld), .out_rdy(pool_out_rdy)
    );

    upsample2x core_up (
        .clk(clk), .rst_n(rst_n),
        .cfg_dim_h(up_dim_h), .cfg_dim_w(up_dim_w), .cfg_ch(cfg_ch),
        .start(up_start), .done(up_done),
        .pixel_in(up_in_data), .pixel_vld(up_in_vld), .pixel_rdy(up_in_rdy),
        .pixel_out(up_out_data), .out_vld(up_out_vld), .out_rdy(up_out_rdy)
    );

    add_layer core_add (
        .clk(clk), .rst_n(rst_n),
        .a_in(elem_a_latch), .a_vld(add_a_vld), .a_rdy(add_a_rdy),
        .b_in(elem_b_data),  .b_vld(add_b_vld), .b_rdy(add_b_rdy),
        .out(add_out_data), .out_vld(add_out_vld), .out_rdy(add_out_rdy)
    );

    subtract_layer core_sub (
        .clk(clk), .rst_n(rst_n),
        .a_in(elem_a_latch), .a_vld(sub_a_vld), .a_rdy(sub_a_rdy),
        .b_in(elem_b_data),  .b_vld(sub_b_vld), .b_rdy(sub_b_rdy),
        .out(sub_out_data), .out_vld(sub_out_vld), .out_rdy(sub_out_rdy)
    );

    sigmoid_lut core_sig (
        .clk(clk), .rst_n(rst_n),
        .pixel_in(add_out_data), .pixel_vld(sig_in_vld), .pixel_rdy(sig_in_rdy),
        .pixel_out(sig_out_data), .out_vld(sig_out_vld), .out_rdy(sig_out_rdy)
    );

    // ==========================================================
    // Block: Datapath Routing (Crossbar MUX)
    // Purpose:
    //   Hoat dong nhu mot tram trung chuyen khong lo. Dua tren 
    //   'datapath_mode' tu FSM, khoi nay se noi dung luong du lieu
    //   tu RAM -> Module tinh toan (Conv/Pool) -> tra ket qua ve RAM.
    // ==========================================================
    always_comb begin

        conv3_out_rdy = 1'b0;
        conv1_in_data = 32'd0;  conv1_in_vld = 1'b0;  conv1_out_rdy = 1'b0;
        relu_in_data  = 32'd0;  relu_in_vld  = 1'b0;  relu_out_rdy  = 1'b0;
        pool_in_data  = 32'd0;  pool_in_vld  = 1'b0;  pool_out_rdy  = 1'b0;
        up_in_data    = 32'd0;  up_in_vld    = 1'b0;  up_out_rdy    = 1'b0;
        add_a_vld     = 1'b0;   add_b_vld    = 1'b0;  add_out_rdy   = 1'b0;
        sub_a_vld     = 1'b0;   sub_b_vld    = 1'b0;  sub_out_rdy   = 1'b0;
        sig_in_vld    = 1'b0;   sig_out_rdy  = 1'b0;
        ram_wea_r     = 1'b0;   ram_dina_r   = 32'd0;
        core_done_r   = 1'b0;
        pad_src_data  = 32'sd0;
        pad_src_vld   = 1'b0;

        case (datapath_mode)

            M_CONV_RELU: begin
                pad_src_data  = ram_douta;
                pad_src_vld   = 1'b1;
                relu_in_data  = conv3_out_data; relu_in_vld  = conv3_out_vld;
                conv3_out_rdy = relu_in_rdy;    relu_out_rdy = 1'b1;
                ram_wea_r     = relu_out_vld;   ram_dina_r   = relu_out_data;
                core_done_r   = conv3_done;
            end

            M_CONV_ONLY: begin
                pad_src_data  = ram_douta;
                pad_src_vld   = 1'b1;
                conv3_out_rdy = 1'b1;
                ram_wea_r     = conv3_out_vld;  ram_dina_r = conv3_out_data;
                core_done_r   = conv3_done;
            end

            M_CONV1: begin
                conv1_in_data = ram_douta;      conv1_in_vld = 1'b1;
                conv1_out_rdy = 1'b1;
                ram_wea_r     = conv1_out_vld;  ram_dina_r = conv1_out_data;
                core_done_r   = conv1_done;
            end

            M_POOL: begin
                pool_in_data  = ram_douta;      pool_in_vld = 1'b1;
                pool_out_rdy  = 1'b1;
                ram_wea_r     = pool_out_vld;   ram_dina_r = pool_out_data;
                core_done_r   = pool_done;
            end

            M_UP_CONV: begin
                up_in_data    = ram_douta;       up_in_vld    = 1'b1;
                pad_src_data  = up_out_data;
                pad_src_vld   = 1'b1;
                up_out_rdy    = pad_ram_rd;
                relu_in_data  = conv3_out_data;  relu_in_vld  = conv3_out_vld;
                conv3_out_rdy = relu_in_rdy;     relu_out_rdy = 1'b1;
                ram_wea_r     = relu_out_vld;    ram_dina_r   = relu_out_data;
                core_done_r   = conv3_done;
            end

            M_SUB: begin
                sub_a_vld   = elem_data_ready;  sub_b_vld = elem_data_ready;
                sub_out_rdy = 1'b1;
                ram_wea_r   = sub_out_vld;  ram_dina_r = sub_out_data;
            end

            M_ADD_SIG: begin
                add_a_vld   = elem_data_ready;  add_b_vld = elem_data_ready;
                sig_in_vld  = add_out_vld;  add_out_rdy = sig_in_rdy;
                sig_out_rdy = 1'b1;
                ram_wea_r   = sig_out_vld;  ram_dina_r = sig_out_data;
            end

            M_ADD_RELU: begin
                add_a_vld    = elem_data_ready;  add_b_vld = elem_data_ready;
                relu_in_data = add_out_data;  relu_in_vld  = add_out_vld;
                add_out_rdy  = relu_in_rdy;   relu_out_rdy = 1'b1;
                ram_wea_r    = relu_out_vld;  ram_dina_r   = relu_out_data;
            end
        endcase
    end

    reg rd_a_hs;

    always_comb begin
        rd_a_hs = 1'b0;

        case (datapath_mode)

            M_CONV_RELU, M_CONV_ONLY: rd_a_hs = pad_ram_rd;

            M_CONV1:  rd_a_hs = conv1_in_vld && conv1_in_rdy;
            M_POOL:   rd_a_hs = pool_in_vld  && pool_in_rdy;

            M_UP_CONV: rd_a_hs = up_in_vld && up_in_rdy;

            M_SUB:                 rd_a_hs = elem_data_ready;
            M_ADD_SIG, M_ADD_RELU: rd_a_hs = elem_data_ready;
        endcase
    end

    assign rd_a_handshake = rd_a_hs && !core_start;
    assign wr_handshake   = ram_wea_r && !core_start;

    
    assign write_masked = 1'b1;

    reg [20:0] pixel_counter;

    wire [20:0] expected_pixels;
    assign expected_pixels = {11'd0, cfg_dim_h} * {11'd0, cfg_dim_w} * {11'd0, cfg_ch};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          pixel_counter <= 21'd0;
        else if (core_start) pixel_counter <= 21'd0;
        else if (elem_mode && wr_handshake)
                             pixel_counter <= pixel_counter + 21'd1;
    end

    wire elem_done = elem_mode && wr_handshake && (pixel_counter == expected_pixels - 21'd1);
    assign core_done = core_done_r || elem_done;

endmodule
