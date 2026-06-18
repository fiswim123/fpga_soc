`timescale 1ns / 1ps

module npu_top #(
    parameter int AXI_ID_W      = 8,
    parameter int AXI_ADDR_W    = 32,
    parameter int AXI_DATA_W    = 32,
    parameter int RAM_AXI_DATA_W = 160,
    parameter int BASE_ADDR     = 32'h0000_2000,
    // NPU 参数
    parameter int MAX_M         = 4,
    parameter int MAX_K         = 5,
    parameter int BLOCK         = 4,
    parameter int BATCH_COUNT   = 144,
    parameter int CORE_NUM      = 40,
    parameter int GROUP_NUM     = 5,
    parameter int LANE_NUM      = 8,
    parameter int IMG_W         = 28,
    parameter int IMG_H         = 28,
    parameter int WIN_W         = 5,
    parameter int WIN_H         = 5,
    parameter int CH_NUM        = 30,
    parameter int POOL_W        = (IMG_W - WIN_W + 1)/2,
    parameter int FC1_OUT       = 100,
    parameter int FC2_OUT       = 10,
    parameter int FC1_PAR       = 4,
    parameter int FC2_IN_PAR    = 20,
    parameter int FC1_BANKS     = 10,
    parameter int FC1_BANK_OUT  = FC1_OUT / FC1_BANKS,
    parameter int FC1_BANKS_PER_CYCLE = 2,
    // Weight files
    parameter A_FILE           = "../src/npu/generated_assets_latest/conv_init.dat",
    parameter FC1_BANK0_FILE   = "../src/npu/generated_assets_latest/fc1_stream_bank0.dat",
    parameter FC1_BANK1_FILE   = "../src/npu/generated_assets_latest/fc1_stream_bank1.dat",
    parameter FC1_BANK2_FILE   = "../src/npu/generated_assets_latest/fc1_stream_bank2.dat",
    parameter FC1_BANK3_FILE   = "../src/npu/generated_assets_latest/fc1_stream_bank3.dat",
    parameter FC1_BANK4_FILE   = "../src/npu/generated_assets_latest/fc1_stream_bank4.dat",
    parameter FC1_BANK5_FILE   = "../src/npu/generated_assets_latest/fc1_stream_bank5.dat",
    parameter FC1_BANK6_FILE   = "../src/npu/generated_assets_latest/fc1_stream_bank6.dat",
    parameter FC1_BANK7_FILE   = "../src/npu/generated_assets_latest/fc1_stream_bank7.dat",
    parameter FC1_BANK8_FILE   = "../src/npu/generated_assets_latest/fc1_stream_bank8.dat",
    parameter FC1_BANK9_FILE   = "../src/npu/generated_assets_latest/fc1_stream_bank9.dat",
    parameter FC2_STREAM_FILE  = "../src/npu/generated_assets_latest/fc2_stream.dat",
    parameter PP_BIAS_FILE     = "../src/npu/generated_assets_latest/pp_bias.memh",
    parameter PP_SHIFT_FILE    = "../src/npu/generated_assets_latest/pp_shift.memh",
    // RAM config
    parameter int RAM_DEPTH    = 1024,
    parameter int RAM_AW       = $clog2(RAM_DEPTH),     // RAM 地址宽度10
    parameter int B_RAM_BASE   = 256           // word offset (0x1400 - 0x1000)/20 = 0x20
)(
    // 时钟与复位
    input  wire                      clk,
    input  wire                      rst_n,

    // AXI4-Lite 从接口 (CSR)
    input  wire                      s_awvalid,
    output wire                      s_awready,
    input  wire [AXI_ADDR_W-1:0]     s_awaddr,
    input  wire [7:0]                s_awlen,
    input  wire [2:0]                s_awsize,
    input  wire [1:0]                s_awburst,
    input  wire [AXI_ID_W-1:0]       s_awid,

    input  wire                      s_wvalid,
    output wire                      s_wready,
    input  wire [AXI_DATA_W-1:0]     s_wdata,
    input  wire [AXI_DATA_W/8-1:0]   s_wstrb,
    input  wire                      s_wlast,

    output wire                      s_bvalid,
    input  wire                      s_bready,
    output wire [1:0]                s_bresp,
    output wire [AXI_ID_W-1:0]       s_bid,

    input  wire                      s_arvalid,
    output wire                      s_arready,
    input  wire [AXI_ADDR_W-1:0]     s_araddr,
    input  wire [7:0]                s_arlen,
    input  wire [2:0]                s_arsize,
    input  wire [1:0]                s_arburst,
    input  wire [AXI_ID_W-1:0]       s_arid,

    output wire                      s_rvalid,
    input  wire                      s_rready,
    output wire [AXI_DATA_W-1:0]     s_rdata,
    output wire [1:0]                s_rresp,
    output wire                      s_rlast,
    output wire [AXI_ID_W-1:0]       s_rid,

    // AXI4 从接口 (NPU RAM)
    // Write Address
    input  wire                       ram_awvalid,
    output wire                       ram_awready,
    input  wire [AXI_ADDR_W-1:0]      ram_awaddr,
    input  wire [7:0]                 ram_awlen,
    input  wire [2:0]                 ram_awsize,
    input  wire [1:0]                 ram_awburst,
    input  wire                       ram_awlock,
    input  wire [3:0]                 ram_awcache,
    input  wire [2:0]                 ram_awprot,
    input  wire [3:0]                 ram_awqos,
    input  wire [3:0]                 ram_awregion,
    input  wire [AXI_ID_W-1:0]        ram_awid,
    input  wire                       ram_awuser,
    // Write Data
    input  wire                       ram_wvalid,
    output wire                       ram_wready,
    input  wire [RAM_AXI_DATA_W-1:0]  ram_wdata,
    input  wire [RAM_AXI_DATA_W/8-1:0]ram_wstrb,
    input  wire                       ram_wlast,
    input  wire                       ram_wuser,
    // Write Response
    output wire                       ram_bvalid,
    input  wire                       ram_bready,
    output wire [AXI_ID_W-1:0]        ram_bid,
    output wire [1:0]                 ram_bresp,
    output wire                       ram_buser,
    // Read Address
    input  wire                       ram_arvalid,
    output wire                       ram_arready,
    input  wire [AXI_ADDR_W-1:0]      ram_araddr,
    input  wire [7:0]                 ram_arlen,
    input  wire [2:0]                 ram_arsize,
    input  wire [1:0]                 ram_arburst,
    input  wire                       ram_arlock,
    input  wire [3:0]                 ram_arcache,
    input  wire [2:0]                 ram_arprot,
    input  wire [3:0]                 ram_arqos,
    input  wire [3:0]                 ram_arregion,
    input  wire [AXI_ID_W-1:0]        ram_arid,
    input  wire                       ram_aruser,
    // Read Data
    output wire                       ram_rvalid,
    input  wire                       ram_rready,
    output wire [AXI_ID_W-1:0]        ram_rid,
    output wire [RAM_AXI_DATA_W-1:0]  ram_rdata,
    output wire [1:0]                 ram_rresp,
    output wire                       ram_rlast,
    output wire                       ram_ruser,

    // NPU 推理结果输出
    output wire                      fc2_valid,
    output wire signed [FC2_OUT*32-1:0] logits_out,
    output wire [3:0]                pred_class
);

    // 内部互联
    logic       np_start;
    logic       np_busy_conv, np_done_conv;
    logic       np_busy_fc,   fc_done;

    localparam int CONV_OUT = IMG_W - WIN_W + 1;      // 24
    localparam int POOL_COUNT = (CONV_OUT/2)*(CONV_OUT/2); // 144
    localparam int POOL_IDX_W = (POOL_COUNT <= 1) ? 1 : $clog2(POOL_COUNT);
    logic [(32*(MAX_M/2)*8)-1:0]  conv_result_out;
    logic                          conv_pool_valid;
    logic [POOL_IDX_W-1:0]        conv_pool_idx;

    // RAM 简单读接口
    wire [RAM_AW-1:0]              b_ram_raddr;
    wire [RAM_AXI_DATA_W-1:0]      b_ram_rdata;

    // RAM 复位 (高有效)
    wire ram_rst = ~rst_n;
/*
    // 监视 RAM 读操作
    always @(b_ram_raddr) begin
        #1; $display("[RAM] addr=%0d data=%h", b_ram_raddr, b_ram_rdata);
    end*/

    // --------------------- NPU RAM (160-bit) ---------------------
    npu_ram_160 #(
        .AXI_DATA_W(RAM_AXI_DATA_W),
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_ID_W(AXI_ID_W),
        .MEM_DEPTH(RAM_DEPTH),
        .INIT_FILE("")
    ) u_npu_ram (
        .clk      (clk),
        .rst      (ram_rst),
        .rd_addr  (b_ram_raddr),
        .rd_data  (b_ram_rdata),
        // AXI slave
        .awvalid  (ram_awvalid),
        .awready  (ram_awready),
        .awaddr   (ram_awaddr),
        .awlen    (ram_awlen),
        .awsize   (ram_awsize),
        .awburst  (ram_awburst),
        .awlock   (ram_awlock),
        .awcache  (ram_awcache),
        .awprot   (ram_awprot),
        .awqos    (ram_awqos),
        .awregion (ram_awregion),
        .awid     (ram_awid),
        .awuser   (ram_awuser),
        .wvalid   (ram_wvalid),
        .wready   (ram_wready),
        .wdata    (ram_wdata),
        .wstrb    (ram_wstrb),
        .wlast    (ram_wlast),
        .wuser    (ram_wuser),
        .bvalid   (ram_bvalid),
        .bready   (ram_bready),
        .bid      (ram_bid),
        .bresp    (ram_bresp),
        .buser    (ram_buser),
        .arvalid  (ram_arvalid),
        .arready  (ram_arready),
        .araddr   (ram_araddr),
        .arlen    (ram_arlen),
        .arsize   (ram_arsize),
        .arburst  (ram_arburst),
        .arlock   (ram_arlock),
        .arcache  (ram_arcache),
        .arprot   (ram_arprot),
        .arqos    (ram_arqos),
        .arregion (ram_arregion),
        .arid     (ram_arid),
        .aruser   (ram_aruser),
        .rvalid   (ram_rvalid),
        .rready   (ram_rready),
        .rid      (ram_rid),
        .rdata    (ram_rdata),
        .rresp    (ram_rresp),
        .rlast    (ram_rlast),
        .ruser    (ram_ruser)
    );

    // --------------------- CSR ---------------------
    npu_csr #(
        .AXI_ID_W   (AXI_ID_W),
        .AXI_ADDR_W (AXI_ADDR_W),
        .AXI_DATA_W (AXI_DATA_W)
    ) u_csr (
        .aclk         (clk),
        .aresetn      (rst_n),
        .s_awvalid    (s_awvalid),
        .s_awready    (s_awready),
        .s_awaddr     (s_awaddr),
        .s_awlen      (s_awlen),
        .s_awsize     (s_awsize),
        .s_awburst    (s_awburst),
        .s_awid       (s_awid),
        .s_wvalid     (s_wvalid),
        .s_wready     (s_wready),
        .s_wdata      (s_wdata),
        .s_wstrb      (s_wstrb),
        .s_wlast      (s_wlast),
        .s_bvalid     (s_bvalid),
        .s_bready     (s_bready),
        .s_bresp      (s_bresp),
        .s_bid        (s_bid),
        .s_arvalid    (s_arvalid),
        .s_arready    (s_arready),
        .s_araddr     (s_araddr),
        .s_arlen      (s_arlen),
        .s_arsize     (s_arsize),
        .s_arburst    (s_arburst),
        .s_arid       (s_arid),
        .s_rvalid     (s_rvalid),
        .s_rready     (s_rready),
        .s_rdata      (s_rdata),
        .s_rresp      (s_rresp),
        .s_rlast      (s_rlast),
        .s_rid        (s_rid),
        .npu_start    (np_start),
        .npu_busy     (np_busy_conv | np_busy_fc),
        .npu_done     (fc_done),
        .result_valid (fc2_valid),
        .pred_class   (pred_class)
    );

    // --------------------- 卷积 + 池化 ---------------------
    npu_cov1 #(
        .MAX_M       (MAX_M),
        .MAX_K       (MAX_K),
        .BLOCK       (BLOCK),
        .BATCH_COUNT (BATCH_COUNT),
        .CORE_NUM    (CORE_NUM),
        .GROUP_NUM   (GROUP_NUM),
        .LANE_NUM    (LANE_NUM),
        .IMG_W       (IMG_W),
        .IMG_H       (IMG_H),
        .WIN_W       (WIN_W),
        .WIN_H       (WIN_H),
        .A_FILE      (A_FILE),
        .B_RAM_BASE  (B_RAM_BASE),
        .B_RAM_AW    (RAM_AW)
    ) u_conv (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (np_start),
        .signed_mode (1'b1),
        .b_ram_raddr (b_ram_raddr),    // 连到 RAM
        .b_ram_rdata (b_ram_rdata),    // 连到 RAM
        .result_out  (conv_result_out),
        .pool_valid  (conv_pool_valid),
        .pool_idx    (conv_pool_idx),
        .busy        (np_busy_conv),
        .done        (np_done_conv)
    );

    // --------------------- 全连接 ---------------------
    npu_fc12 #(
        .CH_NUM              (CH_NUM),
        .POOL_W              (POOL_W),
        .FC1_OUT             (FC1_OUT),
        .FC2_OUT             (FC2_OUT),
        .FC1_PAR             (FC1_PAR),
        .FC2_IN_PAR          (FC2_IN_PAR),
        .FC1_BANKS           (FC1_BANKS),
        .FC1_BANK_OUT        (FC1_BANK_OUT),
        .FC1_BANKS_PER_CYCLE (FC1_BANKS_PER_CYCLE),
        .FC1_STREAM_BANK0_FILE (FC1_BANK0_FILE),
        .FC1_STREAM_BANK1_FILE (FC1_BANK1_FILE),
        .FC1_STREAM_BANK2_FILE (FC1_BANK2_FILE),
        .FC1_STREAM_BANK3_FILE (FC1_BANK3_FILE),
        .FC1_STREAM_BANK4_FILE (FC1_BANK4_FILE),
        .FC1_STREAM_BANK5_FILE (FC1_BANK5_FILE),
        .FC1_STREAM_BANK6_FILE (FC1_BANK6_FILE),
        .FC1_STREAM_BANK7_FILE (FC1_BANK7_FILE),
        .FC1_STREAM_BANK8_FILE (FC1_BANK8_FILE),
        .FC1_STREAM_BANK9_FILE (FC1_BANK9_FILE),
        .FC2_STREAM_FILE      (FC2_STREAM_FILE),
        .PP_BIAS_FILE         (PP_BIAS_FILE),
        .PP_SHIFT_FILE        (PP_SHIFT_FILE)
    ) u_fc (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (np_start),
        .result_clear   (1'b0),
        .pool_valid     (conv_pool_valid),
        .pool_idx       (conv_pool_idx),
        .result_out     (conv_result_out),
        .fc1_valid      (),
        .fc1_out        (),
        .fc1_vec_valid  (),
        .fc1_vec_mask   (),
        .fc1_vec_out    (),
        .fc2_valid      (fc2_valid),
        .logits_out     (logits_out),
        .pred_class     (pred_class),
        .result_valid   (),
        .result_logits  (),
        .result_pred_class (),
        .busy           (np_busy_fc),
        .done           (fc_done)
    );

endmodule