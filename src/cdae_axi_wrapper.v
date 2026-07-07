`timescale 1ns/1ps
// ==========================================================
// Module: AXI4-Lite Wrapper
// Purpose:
//   Giao tiep giua he thong ngoai (Zynq PS) va loi CDAE (PL).
//   Cung cap cac thanh ghi (Registers) de PS dieu khien (Start, 
//   Done) va mot khong gian dia chi RAM de PS ghi Input / doc Output.
// ==========================================================
module cdae_axi_wrapper #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 5
) (

    input  wire                                S_AXI_ACLK,
    input  wire                                S_AXI_ARESETN,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       S_AXI_AWADDR,
    input  wire [2:0]                          S_AXI_AWPROT,
    input  wire                                S_AXI_AWVALID,
    output wire                                S_AXI_AWREADY,

    input  wire [C_S_AXI_DATA_WIDTH-1:0]       S_AXI_WDATA,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0]     S_AXI_WSTRB,
    input  wire                                S_AXI_WVALID,
    output wire                                S_AXI_WREADY,

    output wire [1:0]                          S_AXI_BRESP,
    output wire                                S_AXI_BVALID,
    input  wire                                S_AXI_BREADY,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       S_AXI_ARADDR,
    input  wire [2:0]                          S_AXI_ARPROT,
    input  wire                                S_AXI_ARVALID,
    output wire                                S_AXI_ARREADY,

    output wire [C_S_AXI_DATA_WIDTH-1:0]       S_AXI_RDATA,
    output wire [1:0]                          S_AXI_RRESP,
    output wire                                S_AXI_RVALID,
    input  wire                                S_AXI_RREADY
);

    wire clk   = S_AXI_ACLK;
    wire rst_n = S_AXI_ARESETN;

    // ==========================================================
    // Block: Internal Declarations & Signals
    // ==========================================================
    reg axi_awready, axi_wready, axi_bvalid;
    reg axi_arready, axi_rvalid;
    reg [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr, axi_araddr;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = 2'b00;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = 2'b00;
    assign S_AXI_RVALID  = axi_rvalid;

    reg        start_pulse;
    reg [20:0] ext_addr_reg;
    reg [15:0] ext_wdata_reg;
    reg        ext_we_pulse;

    wire        done_inference;
    wire [15:0] ext_douta;
    reg         inference_busy;

    // ==========================================================
    // Block: Core Instantiation
    // Purpose: Khoi tao module Top cua mang CDAE.
    // ==========================================================
    cdae_core_top core_inst (
        .clk(clk),
        .rst_n(rst_n),
        .ext_dina(ext_wdata_reg),
        .ext_addra(ext_addr_reg),
        .ext_wea(ext_we_pulse),
        .ext_douta(ext_douta),
        .start_inference(start_pulse),
        .done_inference(done_inference)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            inference_busy <= 1'b0;
        else if (start_pulse)
            inference_busy <= 1'b1;
        else if (done_inference)
            inference_busy <= 1'b0;
    end

    // ==========================================================
    // Block: AXI Write FSM
    // Purpose: Dieu khien giao thuc bat tay ghi du lieu (AW & W).
    // ==========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_awready <= 1'b0;
            axi_awaddr  <= 0;
        end else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID) begin
            axi_awready <= 1'b1;
            axi_awaddr  <= S_AXI_AWADDR;
        end else begin
            axi_awready <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            axi_wready <= 1'b0;
        else if (~axi_wready && S_AXI_AWVALID && S_AXI_WVALID)
            axi_wready <= 1'b1;
        else
            axi_wready <= 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            axi_bvalid <= 1'b0;
        else if (axi_awready && S_AXI_AWVALID && axi_wready && S_AXI_WVALID && ~axi_bvalid)
            axi_bvalid <= 1'b1;
        else if (S_AXI_BREADY && axi_bvalid)
            axi_bvalid <= 1'b0;
    end

    wire wr_en = axi_awready && S_AXI_AWVALID && axi_wready && S_AXI_WVALID;
    wire [2:0] wr_addr = axi_awaddr[4:2];

    // ==========================================================
    // Block: Control Registers FSM
    // Purpose: Giai ma dia chi va chot du lieu vao cac Register cua he thong.
    // ==========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_pulse    <= 1'b0;
            ext_addr_reg   <= 21'd0;
            ext_wdata_reg  <= 16'd0;
            ext_we_pulse   <= 1'b0;
        end else begin

            start_pulse  <= 1'b0;
            ext_we_pulse <= 1'b0;

            if (wr_en) begin
                case (wr_addr)
                    3'd0: begin
                        if (S_AXI_WDATA[0])
                            start_pulse <= 1'b1;
                    end
                    3'd2: begin
                        ext_addr_reg <= S_AXI_WDATA[20:0];
                    end
                    3'd3: begin
                        ext_wdata_reg <= S_AXI_WDATA[15:0];
                        ext_we_pulse  <= 1'b1;
                    end
                endcase
            end
        end
    end

    // ==========================================================
    // Block: AXI Read FSM
    // Purpose: Tra du lieu tu cac Register / RAM ve lai Zynq PS.
    // ==========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_arready <= 1'b0;
            axi_araddr  <= 0;
        end else if (~axi_arready && S_AXI_ARVALID) begin
            axi_arready <= 1'b1;
            axi_araddr  <= S_AXI_ARADDR;
        end else begin
            axi_arready <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_rvalid <= 1'b0;
            axi_rdata  <= 0;
        end else if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
            axi_rvalid <= 1'b1;
            case (axi_araddr[4:2])
                3'd0: axi_rdata <= {31'd0, start_pulse};
                3'd1: axi_rdata <= {30'd0, inference_busy, done_inference};
                3'd2: axi_rdata <= {11'd0, ext_addr_reg};
                3'd4: axi_rdata <= {16'd0, ext_douta};
                default: axi_rdata <= 32'd0;
            endcase
        end else if (axi_rvalid && S_AXI_RREADY) begin
            axi_rvalid <= 1'b0;
        end
    end

endmodule
