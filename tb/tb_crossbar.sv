`timescale 1ns/1ps
`default_nettype none

module tb_crossbar;

  localparam int AXI_ADDR_W = 32;
  localparam int AXI_DATA_W = 32;
  localparam int AXI_ID_W   = 8;

  // 地址映射
  localparam logic [31:0] DDR_BASE      = 32'h0000_0000; // S0
  localparam logic [31:0] NPU_LMEM_BASE = 32'h0000_1000; // S1
  localparam logic [31:0] DMA_REG_BASE  = 32'h0000_2000; // S2
  localparam logic [31:0] NPU_REG_BASE  = 32'h0000_3000; // S3

  // 寄存器偏移
  localparam logic [31:0] REG_CTRL   = 32'h000;
  localparam logic [31:0] REG_STATUS = 32'h004;
  localparam logic [31:0] REG_SRC    = 32'h008;
  localparam logic [31:0] REG_DST    = 32'h00C;
  localparam logic [31:0] REG_LEN    = 32'h010;

  logic aclk, aresetn, srst;

  initial begin
    aclk = 1'b0;
    forever #5 aclk = ~aclk;
  end

  initial begin
    aresetn = 1'b0;
    srst    = 1'b1;
    repeat (10) @(posedge aclk);
    aresetn = 1'b1;
    srst    = 1'b0;
  end

  // ==========================================================================
  // CPU AXI4-Lite interface
  // ==========================================================================
  logic [AXI_ADDR_W-1:0] cpu_lite_awaddr;
  logic                  cpu_lite_awvalid;
  logic                  cpu_lite_awready;
  logic [AXI_DATA_W-1:0] cpu_lite_wdata;
  logic [AXI_DATA_W/8-1:0] cpu_lite_wstrb;
  logic                  cpu_lite_wvalid;
  logic                  cpu_lite_wready;
  logic [1:0]            cpu_lite_bresp;
  logic                  cpu_lite_bvalid;
  logic                  cpu_lite_bready;
  logic [AXI_ADDR_W-1:0] cpu_lite_araddr;
  logic                  cpu_lite_arvalid;
  logic                  cpu_lite_arready;
  logic [AXI_DATA_W-1:0] cpu_lite_rdata;
  logic [1:0]            cpu_lite_rresp;
  logic                  cpu_lite_rvalid;
  logic                  cpu_lite_rready;

  // ==========================================================================
  // CPU bridged AXI4 master interface (to crossbar slv0)
  // ==========================================================================
  logic [AXI_ID_W-1:0]   cpu_axi_awid;
  logic [AXI_ADDR_W-1:0] cpu_axi_awaddr;
  logic [7:0]            cpu_axi_awlen;
  logic [2:0]            cpu_axi_awsize;
  logic [1:0]            cpu_axi_awburst;
  logic                  cpu_axi_awvalid;
  logic                  cpu_axi_awready;
  logic [AXI_ID_W-1:0]   cpu_axi_wid;
  logic [AXI_DATA_W-1:0] cpu_axi_wdata;
  logic [AXI_DATA_W/8-1:0] cpu_axi_wstrb;
  logic                  cpu_axi_wlast;
  logic                  cpu_axi_wvalid;
  logic                  cpu_axi_wready;
  logic [AXI_ID_W-1:0]   cpu_axi_bid;
  logic [1:0]            cpu_axi_bresp;
  logic                  cpu_axi_bvalid;
  logic                  cpu_axi_bready;
  logic [AXI_ID_W-1:0]   cpu_axi_arid;
  logic [AXI_ADDR_W-1:0] cpu_axi_araddr;
  logic [7:0]            cpu_axi_arlen;
  logic [2:0]            cpu_axi_arsize;
  logic [1:0]            cpu_axi_arburst;
  logic                  cpu_axi_arvalid;
  logic                  cpu_axi_arready;
  logic [AXI_ID_W-1:0]   cpu_axi_rid;
  logic [AXI_DATA_W-1:0] cpu_axi_rdata;
  logic [1:0]            cpu_axi_rresp;
  logic                  cpu_axi_rlast;
  logic                  cpu_axi_rvalid;
  logic                  cpu_axi_rready;

  // ==========================================================================
  // DMA AXI4 master interface (to crossbar slv1)
  // ==========================================================================
  logic [AXI_ID_W-1:0]   dma_axi_awid;
  logic [AXI_ADDR_W-1:0] dma_axi_awaddr;
  logic [7:0]            dma_axi_awlen;
  logic [2:0]            dma_axi_awsize;
  logic [1:0]            dma_axi_awburst;
  logic                  dma_axi_awvalid;
  logic                  dma_axi_awready;
  logic [AXI_DATA_W-1:0] dma_axi_wdata;
  logic [AXI_DATA_W/8-1:0] dma_axi_wstrb;
  logic                  dma_axi_wlast;
  logic                  dma_axi_wvalid;
  logic                  dma_axi_wready;
  logic [AXI_ID_W-1:0]   dma_axi_bid;
  logic [1:0]            dma_axi_bresp;
  logic                  dma_axi_bvalid;
  logic                  dma_axi_bready;
  logic [AXI_ID_W-1:0]   dma_axi_arid;
  logic [AXI_ADDR_W-1:0] dma_axi_araddr;
  logic [7:0]            dma_axi_arlen;
  logic [2:0]            dma_axi_arsize;
  logic [1:0]            dma_axi_arburst;
  logic                  dma_axi_arvalid;
  logic                  dma_axi_arready;
  logic [AXI_ID_W-1:0]   dma_axi_rid;
  logic [AXI_DATA_W-1:0] dma_axi_rdata;
  logic [1:0]            dma_axi_rresp;
  logic                  dma_axi_rlast;
  logic                  dma_axi_rvalid;
  logic                  dma_axi_rready;

  // ==========================================================================
  // Crossbar slave-side exported ports (mst0..mst3) -> our stub slaves
  // ==========================================================================
  // S0
  logic                  xbar_s0_awvalid;
  logic                  xbar_s0_awready;
  logic [AXI_ADDR_W-1:0] xbar_s0_awaddr;
  logic [7:0]            xbar_s0_awlen;
  logic [2:0]            xbar_s0_awsize;
  logic [1:0]            xbar_s0_awburst;
  logic                  xbar_s0_awlock;
  logic [3:0]            xbar_s0_awcache;
  logic [2:0]            xbar_s0_awprot;
  logic [3:0]            xbar_s0_awqos;
  logic [3:0]            xbar_s0_awregion;
  logic [AXI_ID_W-1:0]   xbar_s0_awid;
  logic                  xbar_s0_wvalid;
  logic                  xbar_s0_wready;
  logic                  xbar_s0_wlast;
  logic [AXI_DATA_W-1:0] xbar_s0_wdata;
  logic [AXI_DATA_W/8-1:0] xbar_s0_wstrb;
  logic                  xbar_s0_bvalid;
  logic                  xbar_s0_bready;
  logic [AXI_ID_W-1:0]   xbar_s0_bid;
  logic [1:0]            xbar_s0_bresp;
  logic                  xbar_s0_arvalid;
  logic                  xbar_s0_arready;
  logic [AXI_ADDR_W-1:0] xbar_s0_araddr;
  logic [7:0]            xbar_s0_arlen;
  logic [2:0]            xbar_s0_arsize;
  logic [1:0]            xbar_s0_arburst;
  logic                  xbar_s0_arlock;
  logic [3:0]            xbar_s0_arcache;
  logic [2:0]            xbar_s0_arprot;
  logic [3:0]            xbar_s0_arqos;
  logic [3:0]            xbar_s0_arregion;
  logic [AXI_ID_W-1:0]   xbar_s0_arid;
  logic                  xbar_s0_rvalid;
  logic                  xbar_s0_rready;
  logic [AXI_ID_W-1:0]   xbar_s0_rid;
  logic [1:0]            xbar_s0_rresp;
  logic [AXI_DATA_W-1:0] xbar_s0_rdata;
  logic                  xbar_s0_rlast;

  // S1
  logic                  xbar_s1_awvalid;
  logic                  xbar_s1_awready;
  logic [AXI_ADDR_W-1:0] xbar_s1_awaddr;
  logic [7:0]            xbar_s1_awlen;
  logic [2:0]            xbar_s1_awsize;
  logic [1:0]            xbar_s1_awburst;
  logic                  xbar_s1_awlock;
  logic [3:0]            xbar_s1_awcache;
  logic [2:0]            xbar_s1_awprot;
  logic [3:0]            xbar_s1_awqos;
  logic [3:0]            xbar_s1_awregion;
  logic [AXI_ID_W-1:0]   xbar_s1_awid;
  logic                  xbar_s1_wvalid;
  logic                  xbar_s1_wready;
  logic                  xbar_s1_wlast;
  logic [AXI_DATA_W-1:0] xbar_s1_wdata;
  logic [AXI_DATA_W/8-1:0] xbar_s1_wstrb;
  logic                  xbar_s1_bvalid;
  logic                  xbar_s1_bready;
  logic [AXI_ID_W-1:0]   xbar_s1_bid;
  logic [1:0]            xbar_s1_bresp;
  logic                  xbar_s1_arvalid;
  logic                  xbar_s1_arready;
  logic [AXI_ADDR_W-1:0] xbar_s1_araddr;
  logic [7:0]            xbar_s1_arlen;
  logic [2:0]            xbar_s1_arsize;
  logic [1:0]            xbar_s1_arburst;
  logic                  xbar_s1_arlock;
  logic [3:0]            xbar_s1_arcache;
  logic [2:0]            xbar_s1_arprot;
  logic [3:0]            xbar_s1_arqos;
  logic [3:0]            xbar_s1_arregion;
  logic [AXI_ID_W-1:0]   xbar_s1_arid;
  logic                  xbar_s1_rvalid;
  logic                  xbar_s1_rready;
  logic [AXI_ID_W-1:0]   xbar_s1_rid;
  logic [1:0]            xbar_s1_rresp;
  logic [AXI_DATA_W-1:0] xbar_s1_rdata;
  logic                  xbar_s1_rlast;

  // S2
  logic                  xbar_s2_awvalid;
  logic                  xbar_s2_awready;
  logic [AXI_ADDR_W-1:0] xbar_s2_awaddr;
  logic [7:0]            xbar_s2_awlen;
  logic [2:0]            xbar_s2_awsize;
  logic [1:0]            xbar_s2_awburst;
  logic                  xbar_s2_awlock;
  logic [3:0]            xbar_s2_awcache;
  logic [2:0]            xbar_s2_awprot;
  logic [3:0]            xbar_s2_awqos;
  logic [3:0]            xbar_s2_awregion;
  logic [AXI_ID_W-1:0]   xbar_s2_awid;
  logic                  xbar_s2_wvalid;
  logic                  xbar_s2_wready;
  logic                  xbar_s2_wlast;
  logic [AXI_DATA_W-1:0] xbar_s2_wdata;
  logic [AXI_DATA_W/8-1:0] xbar_s2_wstrb;
  logic                  xbar_s2_bvalid;
  logic                  xbar_s2_bready;
  logic [AXI_ID_W-1:0]   xbar_s2_bid;
  logic [1:0]            xbar_s2_bresp;
  logic                  xbar_s2_arvalid;
  logic                  xbar_s2_arready;
  logic [AXI_ADDR_W-1:0] xbar_s2_araddr;
  logic [7:0]            xbar_s2_arlen;
  logic [2:0]            xbar_s2_arsize;
  logic [1:0]            xbar_s2_arburst;
  logic                  xbar_s2_arlock;
  logic [3:0]            xbar_s2_arcache;
  logic [2:0]            xbar_s2_arprot;
  logic [3:0]            xbar_s2_arqos;
  logic [3:0]            xbar_s2_arregion;
  logic [AXI_ID_W-1:0]   xbar_s2_arid;
  logic                  xbar_s2_rvalid;
  logic                  xbar_s2_rready;
  logic [AXI_ID_W-1:0]   xbar_s2_rid;
  logic [1:0]            xbar_s2_rresp;
  logic [AXI_DATA_W-1:0] xbar_s2_rdata;
  logic                  xbar_s2_rlast;

  // S3
  logic                  xbar_s3_awvalid;
  logic                  xbar_s3_awready;
  logic [AXI_ADDR_W-1:0] xbar_s3_awaddr;
  logic [7:0]            xbar_s3_awlen;
  logic [2:0]            xbar_s3_awsize;
  logic [1:0]            xbar_s3_awburst;
  logic                  xbar_s3_awlock;
  logic [3:0]            xbar_s3_awcache;
  logic [2:0]            xbar_s3_awprot;
  logic [3:0]            xbar_s3_awqos;
  logic [3:0]            xbar_s3_awregion;
  logic [AXI_ID_W-1:0]   xbar_s3_awid;
  logic                  xbar_s3_wvalid;
  logic                  xbar_s3_wready;
  logic                  xbar_s3_wlast;
  logic [AXI_DATA_W-1:0] xbar_s3_wdata;
  logic [AXI_DATA_W/8-1:0] xbar_s3_wstrb;
  logic                  xbar_s3_bvalid;
  logic                  xbar_s3_bready;
  logic [AXI_ID_W-1:0]   xbar_s3_bid;
  logic [1:0]            xbar_s3_bresp;
  logic                  xbar_s3_arvalid;
  logic                  xbar_s3_arready;
  logic [AXI_ADDR_W-1:0] xbar_s3_araddr;
  logic [7:0]            xbar_s3_arlen;
  logic [2:0]            xbar_s3_arsize;
  logic [1:0]            xbar_s3_arburst;
  logic                  xbar_s3_arlock;
  logic [3:0]            xbar_s3_arcache;
  logic [2:0]            xbar_s3_arprot;
  logic [3:0]            xbar_s3_arqos;
  logic [3:0]            xbar_s3_arregion;
  logic [AXI_ID_W-1:0]   xbar_s3_arid;
  logic                  xbar_s3_rvalid;
  logic                  xbar_s3_rready;
  logic [AXI_ID_W-1:0]   xbar_s3_rid;
  logic [1:0]            xbar_s3_rresp;
  logic [AXI_DATA_W-1:0] xbar_s3_rdata;
  logic                  xbar_s3_rlast;

  // ==========================================================================
  // AXI-Lite to AXI bridge
  // ==========================================================================
  axi_lite2axi #(
    .DATA_WIDTH(AXI_DATA_W),
    .ADDR_WIDTH(AXI_ADDR_W),
    .ID_WIDTH(AXI_ID_W)
  ) u_cpu_lite2axi (
    .aclk(aclk),
    .aresetn(aresetn),
    .s_axi_lite_awaddr(cpu_lite_awaddr),
    .s_axi_lite_awvalid(cpu_lite_awvalid),
    .s_axi_lite_awready(cpu_lite_awready),
    .s_axi_lite_wdata(cpu_lite_wdata),
    .s_axi_lite_wstrb(cpu_lite_wstrb),
    .s_axi_lite_wvalid(cpu_lite_wvalid),
    .s_axi_lite_wready(cpu_lite_wready),
    .s_axi_lite_bresp(cpu_lite_bresp),
    .s_axi_lite_bvalid(cpu_lite_bvalid),
    .s_axi_lite_bready(cpu_lite_bready),
    .s_axi_lite_araddr(cpu_lite_araddr),
    .s_axi_lite_arvalid(cpu_lite_arvalid),
    .s_axi_lite_arready(cpu_lite_arready),
    .s_axi_lite_rdata(cpu_lite_rdata),
    .s_axi_lite_rresp(cpu_lite_rresp),
    .s_axi_lite_rvalid(cpu_lite_rvalid),
    .s_axi_lite_rready(cpu_lite_rready),

    .m_axi_awid(cpu_axi_awid),
    .m_axi_awaddr(cpu_axi_awaddr),
    .m_axi_awlen(cpu_axi_awlen),
    .m_axi_awsize(cpu_axi_awsize),
    .m_axi_awburst(cpu_axi_awburst),
    .m_axi_awvalid(cpu_axi_awvalid),
    .m_axi_awready(cpu_axi_awready),
    .m_axi_wid(cpu_axi_wid),
    .m_axi_wdata(cpu_axi_wdata),
    .m_axi_wstrb(cpu_axi_wstrb),
    .m_axi_wlast(cpu_axi_wlast),
    .m_axi_wvalid(cpu_axi_wvalid),
    .m_axi_wready(cpu_axi_wready),
    .m_axi_bid(cpu_axi_bid),
    .m_axi_bresp(cpu_axi_bresp),
    .m_axi_bvalid(cpu_axi_bvalid),
    .m_axi_bready(cpu_axi_bready),
    .m_axi_arid(cpu_axi_arid),
    .m_axi_araddr(cpu_axi_araddr),
    .m_axi_arlen(cpu_axi_arlen),
    .m_axi_arsize(cpu_axi_arsize),
    .m_axi_arburst(cpu_axi_arburst),
    .m_axi_arvalid(cpu_axi_arvalid),
    .m_axi_arready(cpu_axi_arready),
    .m_axi_rid(cpu_axi_rid),
    .m_axi_rdata(cpu_axi_rdata),
    .m_axi_rresp(cpu_axi_rresp),
    .m_axi_rlast(cpu_axi_rlast),
    .m_axi_rvalid(cpu_axi_rvalid),
    .m_axi_rready(cpu_axi_rready)
  );

  // =========================
// 1) Crossbar params: CPU-only
// =========================
axicb_crossbar_top #(
  .AXI_ADDR_W(AXI_ADDR_W),
  .AXI_ID_W(AXI_ID_W),          // 建议 AXI_ID_W=8
  .AXI_DATA_W(AXI_DATA_W),
  .MST_NB(4),                  
  .SLV_NB(4),
  .MST_PIPELINE(0),
  .SLV_PIPELINE(0),
  .AXI_SIGNALING(1),
  .USER_SUPPORT(0),
  .TIMEOUT_ENABLE(0),

  .MST0_CDC(0),
  .MST0_OSTDREQ_NUM(4),
  .MST0_OSTDREQ_SIZE(1),
  .MST0_PRIORITY(0),
  .MST0_ROUTES(4'b1111),
  .MST0_ID_MASK(8'h10),         // 关键：CPU 用 0 前缀

  .MST1_CDC(0),
  .MST1_OSTDREQ_NUM(1),
  .MST1_OSTDREQ_SIZE(1),
  .MST1_PRIORITY(0),
  .MST1_ROUTES(4'b1111),
  .MST1_ID_MASK(8'h20),

  .MST2_CDC(0),
  .MST2_OSTDREQ_NUM(1),
  .MST2_OSTDREQ_SIZE(1),
  .MST2_PRIORITY(0),
  .MST2_ROUTES(4'b0000),
  .MST2_ID_MASK(8'h30),

  .MST3_CDC(0),
  .MST3_OSTDREQ_NUM(1),
  .MST3_OSTDREQ_SIZE(1),
  .MST3_PRIORITY(0),
  .MST3_ROUTES(4'b0000),
  .MST3_ID_MASK(8'h40),

  .SLV0_CDC(0),
  .SLV0_START_ADDR(32'h0000_0000),
  .SLV0_END_ADDR  (32'h0000_0FFF),
  .SLV0_OSTDREQ_NUM(4),
  .SLV0_OSTDREQ_SIZE(1),
  .SLV0_KEEP_BASE_ADDR(0),

  .SLV1_CDC(0),
  .SLV1_START_ADDR(32'h0000_1000),
  .SLV1_END_ADDR  (32'h0000_1FFF),
  .SLV1_OSTDREQ_NUM(4),
  .SLV1_OSTDREQ_SIZE(1),
  .SLV1_KEEP_BASE_ADDR(0),

  .SLV2_CDC(0),
  .SLV2_START_ADDR(32'h0000_2000),
  .SLV2_END_ADDR  (32'h0000_2FFF),
  .SLV2_OSTDREQ_NUM(4),
  .SLV2_OSTDREQ_SIZE(1),
  .SLV2_KEEP_BASE_ADDR(0),

  .SLV3_CDC(0),
  .SLV3_START_ADDR(32'h0000_3000),
  .SLV3_END_ADDR  (32'h0000_3FFF),
  .SLV3_OSTDREQ_NUM(4),
  .SLV3_OSTDREQ_SIZE(1),
  .SLV3_KEEP_BASE_ADDR(0)
) u_crossbar (
  .aclk(aclk),
  .aresetn(aresetn),
  .srst(srst),

  // slv0 = CPU bridge
  .slv0_aclk(aclk),
  .slv0_aresetn(aresetn),
  .slv0_srst(srst),
  .slv0_awvalid(cpu_axi_awvalid),
  .slv0_awready(cpu_axi_awready),
  .slv0_awaddr(cpu_axi_awaddr),
  .slv0_awlen(cpu_axi_awlen),
  .slv0_awsize(cpu_axi_awsize),
  .slv0_awburst(cpu_axi_awburst),
  .slv0_awlock(1'b0),
  .slv0_awcache(4'b0),
  .slv0_awprot(3'b0),
  .slv0_awqos(4'b0),
  .slv0_awregion(4'b0),
  .slv0_awid(cpu_axi_awid),
  .slv0_awuser(1'b0),
  .slv0_wvalid(cpu_axi_wvalid),
  .slv0_wready(cpu_axi_wready),
  .slv0_wlast(cpu_axi_wlast),
  .slv0_wdata(cpu_axi_wdata),
  .slv0_wstrb(cpu_axi_wstrb),
  .slv0_wuser(1'b0),
  .slv0_bvalid(cpu_axi_bvalid),
  .slv0_bready(cpu_axi_bready),
  .slv0_bid(cpu_axi_bid),
  .slv0_bresp(cpu_axi_bresp),
  .slv0_buser(),
  .slv0_arvalid(cpu_axi_arvalid),
  .slv0_arready(cpu_axi_arready),
  .slv0_araddr(cpu_axi_araddr),
  .slv0_arlen(cpu_axi_arlen),
  .slv0_arsize(cpu_axi_arsize),
  .slv0_arburst(cpu_axi_arburst),
  .slv0_arlock(1'b0),
  .slv0_arcache(4'b0),
  .slv0_arprot(3'b0),
  .slv0_arqos(4'b0),
  .slv0_arregion(4'b0),
  .slv0_arid(cpu_axi_arid),
  .slv0_aruser(1'b0),
  .slv0_rvalid(cpu_axi_rvalid),
  .slv0_rready(cpu_axi_rready),
  .slv0_rid(cpu_axi_rid),
  .slv0_rresp(cpu_axi_rresp),
  .slv0_rdata(cpu_axi_rdata),
  .slv0_rlast(cpu_axi_rlast),
  .slv0_ruser(),

  // slv1 = DMA master
  .slv1_aclk(aclk),
  .slv1_aresetn(aresetn),
  .slv1_srst(srst),
  
  .slv1_awvalid(dma_axi_awvalid),
  .slv1_awready(dma_axi_awready),
  .slv1_awaddr (dma_axi_awaddr),
  .slv1_awlen  (dma_axi_awlen),
  .slv1_awsize (dma_axi_awsize),
  .slv1_awburst(dma_axi_awburst),
  .slv1_awlock (1'b0),
  .slv1_awcache(4'b0),
  .slv1_awprot (3'b0),
  .slv1_awqos  (4'b0),
  .slv1_awregion(4'b0),
  .slv1_awid   (dma_axi_awid),
  .slv1_awuser (1'b0),
  
  .slv1_wvalid(dma_axi_wvalid),
  .slv1_wready(dma_axi_wready),
  .slv1_wlast (dma_axi_wlast),
  .slv1_wdata (dma_axi_wdata),
  .slv1_wstrb (dma_axi_wstrb),
  .slv1_wuser (1'b0),
  
  .slv1_bvalid(dma_axi_bvalid),
  .slv1_bready(dma_axi_bready),
  .slv1_bid   (dma_axi_bid),
  .slv1_bresp (dma_axi_bresp),
  .slv1_buser (),
  
  .slv1_arvalid(dma_axi_arvalid),
  .slv1_arready(dma_axi_arready),
  .slv1_araddr (dma_axi_araddr),
  .slv1_arlen  (dma_axi_arlen),
  .slv1_arsize (dma_axi_arsize),
  .slv1_arburst(dma_axi_arburst),
  .slv1_arlock (1'b0),
  .slv1_arcache(4'b0),
  .slv1_arprot (3'b0),
  .slv1_arqos  (4'b0),
  .slv1_arregion(4'b0),
  .slv1_arid   (dma_axi_arid),
  .slv1_aruser (1'b0),
  
  .slv1_rvalid(dma_axi_rvalid),
  .slv1_rready(dma_axi_rready),
  .slv1_rid   (dma_axi_rid),
  .slv1_rresp (dma_axi_rresp),
  .slv1_rdata (dma_axi_rdata),
  .slv1_rlast (dma_axi_rlast),
  .slv1_ruser (),
// 3) slv2/slv3 全部绑0
.slv2_aclk(aclk),.slv2_aresetn(aresetn),.slv2_srst(srst),
.slv2_awvalid(1'b0), .slv2_awaddr('0), .slv2_awlen('0), .slv2_awsize('0), .slv2_awburst('0),
.slv2_awlock(1'b0), .slv2_awcache(4'b0), .slv2_awprot(3'b0), .slv2_awqos(4'b0), .slv2_awregion(4'b0), .slv2_awid('0), .slv2_awuser(1'b0),
.slv2_wvalid(1'b0), .slv2_wlast(1'b0), .slv2_wdata('0), .slv2_wstrb('0), .slv2_wuser(1'b0),
.slv2_bready(1'b0),
.slv2_arvalid(1'b0), .slv2_araddr('0), .slv2_arlen('0), .slv2_arsize('0), .slv2_arburst('0),
.slv2_arlock(1'b0), .slv2_arcache(4'b0), .slv2_arprot(3'b0), .slv2_arqos(4'b0), .slv2_arregion(4'b0), .slv2_arid('0), .slv2_aruser(1'b0),
.slv2_rready(1'b0),
// outputs from crossbar
.slv2_awready (), 
.slv2_wready  (),
.slv2_bvalid  (),
.slv2_bid     (),
.slv2_bresp   (),
.slv2_buser   (),
.slv2_arready (),
.slv2_rvalid  (),
.slv2_rid     (),
.slv2_rresp   (),
.slv2_rdata   (),
.slv2_rlast   (),
.slv2_ruser   (),

.slv3_aclk(aclk),.slv3_aresetn(aresetn),.slv3_srst(srst),
.slv3_awvalid(1'b0), .slv3_awaddr('0), .slv3_awlen('0), .slv3_awsize('0), .slv3_awburst('0),
.slv3_awlock(1'b0), .slv3_awcache(4'b0), .slv3_awprot(3'b0), .slv3_awqos(4'b0), .slv3_awregion(4'b0), .slv3_awid('0), .slv3_awuser(1'b0),
.slv3_wvalid(1'b0), .slv3_wlast(1'b0), .slv3_wdata('0), .slv3_wstrb('0), .slv3_wuser(1'b0),
.slv3_bready(1'b0),
.slv3_arvalid(1'b0), .slv3_araddr('0), .slv3_arlen('0), .slv3_arsize('0), .slv3_arburst('0),
.slv3_arlock(1'b0), .slv3_arcache(4'b0), .slv3_arprot(3'b0), .slv3_arqos(4'b0), .slv3_arregion(4'b0), .slv3_arid('0), .slv3_aruser(1'b0),
.slv3_rready(1'b0),
// outputs from crossbar
.slv3_awready (), 
.slv3_wready  (),
.slv3_bvalid  (),
.slv3_bid     (),
.slv3_bresp   (),
.slv3_buser   (),
.slv3_arready (),
.slv3_rvalid  (),
.slv3_rid     (),
.slv3_rresp   (),
.slv3_rdata   (),
.slv3_rlast   (),
.slv3_ruser   (),

  // mst0..mst3 全部连 xbar_s0..s3（mem or reg slaves）
  .mst0_aclk(aclk), .mst0_aresetn(aresetn), .mst0_srst(srst),
  .mst0_awvalid(xbar_s0_awvalid), .mst0_awready(xbar_s0_awready), .mst0_awaddr(xbar_s0_awaddr), .mst0_awlen(xbar_s0_awlen),
  .mst0_awsize(xbar_s0_awsize), .mst0_awburst(xbar_s0_awburst), .mst0_awlock(xbar_s0_awlock), .mst0_awcache(xbar_s0_awcache),
  .mst0_awprot(xbar_s0_awprot), .mst0_awqos(xbar_s0_awqos), .mst0_awregion(xbar_s0_awregion), .mst0_awid(xbar_s0_awid), .mst0_awuser(),
  .mst0_wvalid(xbar_s0_wvalid), .mst0_wready(xbar_s0_wready), .mst0_wlast(xbar_s0_wlast), .mst0_wdata(xbar_s0_wdata), .mst0_wstrb(xbar_s0_wstrb), .mst0_wuser(),
  .mst0_bvalid(xbar_s0_bvalid), .mst0_bready(xbar_s0_bready), .mst0_bid(xbar_s0_bid), .mst0_bresp(xbar_s0_bresp), .mst0_buser(1'b0),
  .mst0_arvalid(xbar_s0_arvalid), .mst0_arready(xbar_s0_arready), .mst0_araddr(xbar_s0_araddr), .mst0_arlen(xbar_s0_arlen),
  .mst0_arsize(xbar_s0_arsize), .mst0_arburst(xbar_s0_arburst), .mst0_arlock(xbar_s0_arlock), .mst0_arcache(xbar_s0_arcache),
  .mst0_arprot(xbar_s0_arprot), .mst0_arqos(xbar_s0_arqos), .mst0_arregion(xbar_s0_arregion), .mst0_arid(xbar_s0_arid), .mst0_aruser(),
  .mst0_rvalid(xbar_s0_rvalid), .mst0_rready(xbar_s0_rready), .mst0_rid(xbar_s0_rid), .mst0_rresp(xbar_s0_rresp), .mst0_rdata(xbar_s0_rdata), .mst0_rlast(xbar_s0_rlast), .mst0_ruser(1'b0),

  .mst1_aclk(aclk), .mst1_aresetn(aresetn), .mst1_srst(srst),
  .mst1_awvalid(xbar_s1_awvalid), .mst1_awready(xbar_s1_awready), .mst1_awaddr(xbar_s1_awaddr), .mst1_awlen(xbar_s1_awlen),
  .mst1_awsize(xbar_s1_awsize), .mst1_awburst(xbar_s1_awburst), .mst1_awlock(xbar_s1_awlock), .mst1_awcache(xbar_s1_awcache),
  .mst1_awprot(xbar_s1_awprot), .mst1_awqos(xbar_s1_awqos), .mst1_awregion(xbar_s1_awregion), .mst1_awid(xbar_s1_awid), .mst1_awuser(),
  .mst1_wvalid(xbar_s1_wvalid), .mst1_wready(xbar_s1_wready), .mst1_wlast(xbar_s1_wlast), .mst1_wdata(xbar_s1_wdata), .mst1_wstrb(xbar_s1_wstrb), .mst1_wuser(),
  .mst1_bvalid(xbar_s1_bvalid), .mst1_bready(xbar_s1_bready), .mst1_bid(xbar_s1_bid), .mst1_bresp(xbar_s1_bresp), .mst1_buser(1'b0),
  .mst1_arvalid(xbar_s1_arvalid), .mst1_arready(xbar_s1_arready), .mst1_araddr(xbar_s1_araddr), .mst1_arlen(xbar_s1_arlen),
  .mst1_arsize(xbar_s1_arsize), .mst1_arburst(xbar_s1_arburst), .mst1_arlock(xbar_s1_arlock), .mst1_arcache(xbar_s1_arcache),
  .mst1_arprot(xbar_s1_arprot), .mst1_arqos(xbar_s1_arqos), .mst1_arregion(xbar_s1_arregion), .mst1_arid(xbar_s1_arid), .mst1_aruser(),
  .mst1_rvalid(xbar_s1_rvalid), .mst1_rready(xbar_s1_rready), .mst1_rid(xbar_s1_rid), .mst1_rresp(xbar_s1_rresp), .mst1_rdata(xbar_s1_rdata), .mst1_rlast(xbar_s1_rlast), .mst1_ruser(1'b0),

  .mst2_aclk(aclk), .mst2_aresetn(aresetn), .mst2_srst(srst),
  .mst2_awvalid(xbar_s2_awvalid), .mst2_awready(xbar_s2_awready), .mst2_awaddr(xbar_s2_awaddr), .mst2_awlen(xbar_s2_awlen),
  .mst2_awsize(xbar_s2_awsize), .mst2_awburst(xbar_s2_awburst), .mst2_awlock(xbar_s2_awlock), .mst2_awcache(xbar_s2_awcache),
  .mst2_awprot(xbar_s2_awprot), .mst2_awqos(xbar_s2_awqos), .mst2_awregion(xbar_s2_awregion), .mst2_awid(xbar_s2_awid), .mst2_awuser(),
  .mst2_wvalid(xbar_s2_wvalid), .mst2_wready(xbar_s2_wready), .mst2_wlast(xbar_s2_wlast), .mst2_wdata(xbar_s2_wdata), .mst2_wstrb(xbar_s2_wstrb), .mst2_wuser(),
  .mst2_bvalid(xbar_s2_bvalid), .mst2_bready(xbar_s2_bready), .mst2_bid(xbar_s2_bid), .mst2_bresp(xbar_s2_bresp), .mst2_buser(1'b0),
  .mst2_arvalid(xbar_s2_arvalid), .mst2_arready(xbar_s2_arready), .mst2_araddr(xbar_s2_araddr), .mst2_arlen(xbar_s2_arlen),
  .mst2_arsize(xbar_s2_arsize), .mst2_arburst(xbar_s2_arburst), .mst2_arlock(xbar_s2_arlock), .mst2_arcache(xbar_s2_arcache),
  .mst2_arprot(xbar_s2_arprot), .mst2_arqos(xbar_s2_arqos), .mst2_arregion(xbar_s2_arregion), .mst2_arid(xbar_s2_arid), .mst2_aruser(),
  .mst2_rvalid(xbar_s2_rvalid), .mst2_rready(xbar_s2_rready), .mst2_rid(xbar_s2_rid), .mst2_rresp(xbar_s2_rresp), .mst2_rdata(xbar_s2_rdata), .mst2_rlast(xbar_s2_rlast), .mst2_ruser(1'b0),

  .mst3_aclk(aclk), .mst3_aresetn(aresetn), .mst3_srst(srst),
  .mst3_awvalid(xbar_s3_awvalid), .mst3_awready(xbar_s3_awready), .mst3_awaddr(xbar_s3_awaddr), .mst3_awlen(xbar_s3_awlen),
  .mst3_awsize(xbar_s3_awsize), .mst3_awburst(xbar_s3_awburst), .mst3_awlock(xbar_s3_awlock), .mst3_awcache(xbar_s3_awcache),
  .mst3_awprot(xbar_s3_awprot), .mst3_awqos(xbar_s3_awqos), .mst3_awregion(xbar_s3_awregion), .mst3_awid(xbar_s3_awid), .mst3_awuser(),
  .mst3_wvalid(xbar_s3_wvalid), .mst3_wready(xbar_s3_wready), .mst3_wlast(xbar_s3_wlast), .mst3_wdata(xbar_s3_wdata), .mst3_wstrb(xbar_s3_wstrb), .mst3_wuser(),
  .mst3_bvalid(xbar_s3_bvalid), .mst3_bready(xbar_s3_bready), .mst3_bid(xbar_s3_bid), .mst3_bresp(xbar_s3_bresp), .mst3_buser(1'b0),
  .mst3_arvalid(xbar_s3_arvalid), .mst3_arready(xbar_s3_arready), .mst3_araddr(xbar_s3_araddr), .mst3_arlen(xbar_s3_arlen),
  .mst3_arsize(xbar_s3_arsize), .mst3_arburst(xbar_s3_arburst), .mst3_arlock(xbar_s3_arlock), .mst3_arcache(xbar_s3_arcache),
  .mst3_arprot(xbar_s3_arprot), .mst3_arqos(xbar_s3_arqos), .mst3_arregion(xbar_s3_arregion), .mst3_arid(xbar_s3_arid), .mst3_aruser(),
  .mst3_rvalid(xbar_s3_rvalid), .mst3_rready(xbar_s3_rready), .mst3_rid(xbar_s3_rid), .mst3_rresp(xbar_s3_rresp), .mst3_rdata(xbar_s3_rdata), .mst3_rlast(xbar_s3_rlast), .mst3_ruser(1'b0)
);

// -------------------------
  // S0 DDR RAM
  // -------------------------
  axi_slave_ram #(
    .AXI_ID_W(AXI_ID_W), .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
    .MEM_BYTES(4096), .READ_LATENCY(1)
  ) u_ddr_ram (
    .aclk(aclk), .aresetn(aresetn),
    .s_awvalid(xbar_s0_awvalid), .s_awready(xbar_s0_awready), .s_awaddr(xbar_s0_awaddr), .s_awlen(xbar_s0_awlen),
    .s_awsize(xbar_s0_awsize), .s_awburst(xbar_s0_awburst), .s_awid(xbar_s0_awid),
    .s_wvalid(xbar_s0_wvalid), .s_wready(xbar_s0_wready), .s_wdata(xbar_s0_wdata), .s_wstrb(xbar_s0_wstrb), .s_wlast(xbar_s0_wlast),
    .s_bvalid(xbar_s0_bvalid), .s_bready(xbar_s0_bready), .s_bresp(xbar_s0_bresp), .s_bid(xbar_s0_bid),
    .s_arvalid(xbar_s0_arvalid), .s_arready(xbar_s0_arready), .s_araddr(xbar_s0_araddr), .s_arlen(xbar_s0_arlen),
    .s_arsize(xbar_s0_arsize), .s_arburst(xbar_s0_arburst), .s_arid(xbar_s0_arid),
    .s_rvalid(xbar_s0_rvalid), .s_rready(xbar_s0_rready), .s_rdata(xbar_s0_rdata), .s_rresp(xbar_s0_rresp), .s_rlast(xbar_s0_rlast), .s_rid(xbar_s0_rid)
  );

  // S1 NPU LMEM RAM
  axi_slave_ram #(
    .AXI_ID_W(AXI_ID_W), .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
    .MEM_BYTES(4096), .READ_LATENCY(1)
  ) u_npu_lmem_ram (
    .aclk(aclk), .aresetn(aresetn),
    .s_awvalid(xbar_s1_awvalid), .s_awready(xbar_s1_awready), .s_awaddr(xbar_s1_awaddr), .s_awlen(xbar_s1_awlen),
    .s_awsize(xbar_s1_awsize), .s_awburst(xbar_s1_awburst), .s_awid(xbar_s1_awid),
    .s_wvalid(xbar_s1_wvalid), .s_wready(xbar_s1_wready), .s_wdata(xbar_s1_wdata), .s_wstrb(xbar_s1_wstrb), .s_wlast(xbar_s1_wlast),
    .s_bvalid(xbar_s1_bvalid), .s_bready(xbar_s1_bready), .s_bresp(xbar_s1_bresp), .s_bid(xbar_s1_bid),
    .s_arvalid(xbar_s1_arvalid), .s_arready(xbar_s1_arready), .s_araddr(xbar_s1_araddr), .s_arlen(xbar_s1_arlen),
    .s_arsize(xbar_s1_arsize), .s_arburst(xbar_s1_arburst), .s_arid(xbar_s1_arid),
    .s_rvalid(xbar_s1_rvalid), .s_rready(xbar_s1_rready), .s_rdata(xbar_s1_rdata), .s_rresp(xbar_s1_rresp), .s_rlast(xbar_s1_rlast), .s_rid(xbar_s1_rid)
  );

  // S2 DMA REG
  axi_slave_reg #(
    .AXI_ID_W(AXI_ID_W), .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
    .BASE_ADDR(32'h0000_2000), .IS_DMA(1)
  ) u_dma_reg (
    .aclk(aclk), .aresetn(aresetn),
    .s_awvalid(xbar_s2_awvalid), .s_awready(xbar_s2_awready), .s_awaddr(xbar_s2_awaddr), .s_awlen(xbar_s2_awlen),
    .s_awsize(xbar_s2_awsize), .s_awburst(xbar_s2_awburst), .s_awid(xbar_s2_awid),
    .s_wvalid(xbar_s2_wvalid), .s_wready(xbar_s2_wready), .s_wdata(xbar_s2_wdata), .s_wstrb(xbar_s2_wstrb), .s_wlast(xbar_s2_wlast),
    .s_bvalid(xbar_s2_bvalid), .s_bready(xbar_s2_bready), .s_bresp(xbar_s2_bresp), .s_bid(xbar_s2_bid),
    .s_arvalid(xbar_s2_arvalid), .s_arready(xbar_s2_arready), .s_araddr(xbar_s2_araddr), .s_arlen(xbar_s2_arlen),
    .s_arsize(xbar_s2_arsize), .s_arburst(xbar_s2_arburst), .s_arid(xbar_s2_arid),
    .s_rvalid(xbar_s2_rvalid), .s_rready(xbar_s2_rready), .s_rdata(xbar_s2_rdata), .s_rresp(xbar_s2_rresp), .s_rlast(xbar_s2_rlast), .s_rid(xbar_s2_rid)
  );

  // S3 NPU REG
  axi_slave_reg #(
    .AXI_ID_W(AXI_ID_W), .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
    .BASE_ADDR(32'h0000_3000), .IS_DMA(0)
  ) u_npu_reg (
    .aclk(aclk), .aresetn(aresetn),
    .s_awvalid(xbar_s3_awvalid), .s_awready(xbar_s3_awready), .s_awaddr(xbar_s3_awaddr), .s_awlen(xbar_s3_awlen),
    .s_awsize(xbar_s3_awsize), .s_awburst(xbar_s3_awburst), .s_awid(xbar_s3_awid),
    .s_wvalid(xbar_s3_wvalid), .s_wready(xbar_s3_wready), .s_wdata(xbar_s3_wdata), .s_wstrb(xbar_s3_wstrb), .s_wlast(xbar_s3_wlast),
    .s_bvalid(xbar_s3_bvalid), .s_bready(xbar_s3_bready), .s_bresp(xbar_s3_bresp), .s_bid(xbar_s3_bid),
    .s_arvalid(xbar_s3_arvalid), .s_arready(xbar_s3_arready), .s_araddr(xbar_s3_araddr), .s_arlen(xbar_s3_arlen),
    .s_arsize(xbar_s3_arsize), .s_arburst(xbar_s3_arburst), .s_arid(xbar_s3_arid),
    .s_rvalid(xbar_s3_rvalid), .s_rready(xbar_s3_rready), .s_rdata(xbar_s3_rdata), .s_rresp(xbar_s3_rresp), .s_rlast(xbar_s3_rlast), .s_rid(xbar_s3_rid)
  );



// ==========================================================
// Unified AXI/Lite debug monitor (single block, no duplicate prints)
// ==========================================================
always @(posedge aclk) begin
  // ---------------- CPU Lite bridge side ----------------
  if (cpu_lite_awvalid && !cpu_lite_awready)
    $display("[DBG][LITE][STALL][AW] t=%0t", $time);
  if (cpu_lite_wvalid  && !cpu_lite_wready)
    $display("[DBG][LITE][STALL][W ] t=%0t", $time);

  if (cpu_lite_bvalid && cpu_lite_bready)
    $display("[DBG][LITE][B ] t=%0t resp=%b%s",
      $time, cpu_lite_bresp, (cpu_lite_bresp==2'b00) ? " OKAY" : " ERR");

  // ---------------- CPU AXI side ----------------
  if (cpu_axi_awvalid && cpu_axi_awready)
    $display("[DBG][CPU ][AW] t=%0t addr=%08h id=%02h len=%0d size=%0d burst=%b",
      $time, cpu_axi_awaddr, cpu_axi_awid, cpu_axi_awlen, cpu_axi_awsize, cpu_axi_awburst);

  if (cpu_axi_wvalid && cpu_axi_wready)
    $display("[DBG][CPU ][W ] t=%0t data=%08h strb=%h last=%b",
      $time, cpu_axi_wdata, cpu_axi_wstrb, cpu_axi_wlast);

  if (cpu_axi_bvalid && cpu_axi_bready)
    $display("[DBG][CPU ][B ] t=%0t resp=%b id=%02h%s",
      $time, cpu_axi_bresp, cpu_axi_bid, (cpu_axi_bresp==2'b00) ? " OKAY" : " ERR");

  if (cpu_axi_arvalid && cpu_axi_arready)
    $display("[DBG][CPU ][AR] t=%0t addr=%08h id=%02h len=%0d size=%0d burst=%b",
      $time, cpu_axi_araddr, cpu_axi_arid, cpu_axi_arlen, cpu_axi_arsize, cpu_axi_arburst);

  if (cpu_axi_rvalid && cpu_axi_rready)
    $display("[DBG][CPU ][R ] t=%0t data=%08h resp=%b id=%02h last=%b%s",
      $time, cpu_axi_rdata, cpu_axi_rresp, cpu_axi_rid, cpu_axi_rlast,
      (cpu_axi_rresp==2'b00) ? " OKAY" : " ERR");

  // ---------------- DMA AXI side ----------------
  if (dma_axi_awvalid && dma_axi_awready)
    $display("[DBG][DMA ][AW] t=%0t addr=%08h id=%02h len=%0d size=%0d burst=%b",
      $time, dma_axi_awaddr, dma_axi_awid, dma_axi_awlen, dma_axi_awsize, dma_axi_awburst);

  if (dma_axi_wvalid && dma_axi_wready)
    $display("[DBG][DMA ][W ] t=%0t data=%08h strb=%h last=%b",
      $time, dma_axi_wdata, dma_axi_wstrb, dma_axi_wlast);

  if (dma_axi_bvalid && dma_axi_bready)
    $display("[DBG][DMA ][B ] t=%0t resp=%b id=%02h%s",
      $time, dma_axi_bresp, dma_axi_bid, (dma_axi_bresp==2'b00) ? " OKAY" : " ERR");

  if (dma_axi_arvalid && dma_axi_arready)
    $display("[DBG][DMA ][AR] t=%0t addr=%08h id=%02h len=%0d size=%0d burst=%b",
      $time, dma_axi_araddr, dma_axi_arid, dma_axi_arlen, dma_axi_arsize, dma_axi_arburst);

  if (dma_axi_rvalid && dma_axi_rready)
    $display("[DBG][DMA ][R ] t=%0t data=%08h resp=%b id=%02h last=%b%s",
      $time, dma_axi_rdata, dma_axi_rresp, dma_axi_rid, dma_axi_rlast,
      (dma_axi_rresp==2'b00) ? " OKAY" : " ERR");

  // ---------------- Crossbar -> slave ports (route visibility) ----------------
  if (xbar_s0_awvalid && xbar_s0_awready)
    $display("[DBG][XBAR][S0][AW] t=%0t addr=%08h id=%02h", $time, xbar_s0_awaddr, xbar_s0_awid);
  if (xbar_s0_wvalid && xbar_s0_wready)
    $display("[DBG][XBAR][S0][W ] t=%0t data=%08h", $time, xbar_s0_wdata);
  if (xbar_s0_bvalid && xbar_s0_bready)
    $display("[DBG][XBAR][S0][B ] t=%0t resp=%b id=%02h", $time, xbar_s0_bresp, xbar_s0_bid);
  if (xbar_s0_arvalid && xbar_s0_arready)
    $display("[DBG][XBAR][S0][AR] t=%0t addr=%08h id=%02h", $time, xbar_s0_araddr, xbar_s0_arid);
  if (xbar_s0_rvalid && xbar_s0_rready)
    $display("[DBG][XBAR][S0][R ] t=%0t data=%08h resp=%b id=%02h", $time, xbar_s0_rdata, xbar_s0_rresp, xbar_s0_rid);

  if (xbar_s1_awvalid && xbar_s1_awready)
    $display("[DBG][XBAR][S1][AW] t=%0t addr=%08h id=%02h", $time, xbar_s1_awaddr, xbar_s1_awid);
  if (xbar_s2_awvalid && xbar_s2_awready)
    $display("[DBG][XBAR][S2][AW] t=%0t addr=%08h id=%02h", $time, xbar_s2_awaddr, xbar_s2_awid);
  if (xbar_s3_awvalid && xbar_s3_awready)
    $display("[DBG][XBAR][S3][AW] t=%0t addr=%08h id=%02h", $time, xbar_s3_awaddr, xbar_s3_awid);
end

// ------------------------------
// FINAL stable CPU/DMA tasks
// - AW/W independent handshake
// - explicit timeout diagnostics
// - DMA task DOES NOT override wstrb
// ------------------------------

task automatic cpu_write_lite(
  input  [31:0] addr,
  input  [31:0] data,
  output bit    ok
);
  int k;
  bit aw_done, w_done, b_done;

  ok      = 1'b1;
  aw_done = 1'b0;
  w_done  = 1'b0;
  b_done  = 1'b0;

  // drive request
  cpu_lite_awaddr  <= addr;
  cpu_lite_wdata   <= data;
  cpu_lite_wstrb   <= 4'hF;
  cpu_lite_awvalid <= 1'b1;
  cpu_lite_wvalid  <= 1'b1;
  cpu_lite_bready  <= 1'b1;

  $display("[WDBG] start t=%0t addr=%08h data=%08h", $time, addr, data);

  // AW/W independent HS
  for (k = 0; k < 2000; k++) begin
    @(posedge aclk);

    if (!aw_done && cpu_lite_awvalid && cpu_lite_awready) begin
      aw_done = 1'b1;
      cpu_lite_awvalid <= 1'b0;
      $display("[WDBG] AW HS t=%0t", $time);
    end

    if (!w_done && cpu_lite_wvalid && cpu_lite_wready) begin
      w_done = 1'b1;
      cpu_lite_wvalid <= 1'b0;
      $display("[WDBG] W  HS t=%0t", $time);
    end

    if (aw_done && w_done) break;
  end

  if (!(aw_done && w_done)) begin
    ok = 1'b0;
    $display("[TB][ERR][cpu_write_lite] AW/W timeout addr=%08h data=%08h aw_done=%0d w_done=%0d t=%0t",
             addr, data, aw_done, w_done, $time);
    cpu_lite_awvalid <= 1'b0;
    cpu_lite_wvalid  <= 1'b0;
    return;
  end

  // re-assert bready before wait-B (防外部覆盖)
  cpu_lite_bready <= 1'b1;

  // wait B
  for (k = 0; k < 4000; k++) begin
    @(posedge aclk);

    if ((k % 200) == 0)
      $display("[WDBG] waitB t=%0t bvalid=%b bready=%b", $time, cpu_lite_bvalid, cpu_lite_bready);

    if (cpu_lite_bvalid && cpu_lite_bready) begin
      b_done = 1'b1;
      $display("[WDBG] B HS t=%0t bresp=%b", $time, cpu_lite_bresp);

      if (cpu_lite_bresp != 2'b00) begin
        ok = 1'b0;
        $display("[TB][ERR][cpu_write_lite] BRESP error addr=%08h data=%08h bresp=%b t=%0t",
                 addr, data, cpu_lite_bresp, $time);
      end
      break;
    end
  end

  if (!b_done) begin
    ok = 1'b0;
    $display("[TB][ERR][cpu_write_lite] B timeout addr=%08h data=%08h t=%0t", addr, data, $time);
  end
endtask

task automatic cpu_read_lite(
  input  [31:0] addr,
  output [31:0] data,
  output bit    ok
);
  int k;
  bit ar_done, r_done;

  ok = 1'b1;
  data = '0;
  ar_done = 1'b0;
  r_done  = 1'b0;

  cpu_lite_araddr  <= addr;
  cpu_lite_arvalid <= 1'b1;
  cpu_lite_rready  <= 1'b1;

  for (k = 0; k < 2000; k++) begin
    @(posedge aclk);
    if (!ar_done && cpu_lite_arvalid && cpu_lite_arready) begin
      ar_done = 1'b1;
      cpu_lite_arvalid <= 1'b0;
      break;
    end
  end

  if (!ar_done) begin
    ok = 1'b0;
    $display("[TB][ERR][cpu_read_lite] AR timeout addr=%08h t=%0t", addr, $time);
    cpu_lite_arvalid <= 1'b0;
    return;
  end

  for (k = 0; k < 4000; k++) begin
    @(posedge aclk);
    if (cpu_lite_rvalid && cpu_lite_rready) begin
      data = cpu_lite_rdata;
      r_done = 1'b1;
      if (cpu_lite_rresp != 2'b00) begin
        ok = 1'b0;
        $display("[TB][ERR][cpu_read_lite] RRESP error addr=%08h rresp=%b data=%08h t=%0t",
                 addr, cpu_lite_rresp, cpu_lite_rdata, $time);
      end
      break;
    end
  end

  if (!r_done) begin
    ok = 1'b0;
    $display("[TB][ERR][cpu_read_lite] R timeout addr=%08h t=%0t", addr, $time);
  end
endtask


task automatic dma_write_axi(
  input  [31:0] addr,
  input  [31:0] data,
  output bit    ok
);
  int k;
  bit aw_done, w_done, b_done;

  ok      = 1'b1;
  aw_done = 1'b0;
  w_done  = 1'b0;
  b_done  = 1'b0;

  dma_axi_awaddr  <= addr;
  dma_axi_wdata   <= data;
  // NOTE: do NOT override dma_axi_wstrb here
  // caller controls partial/full write via dma_axi_wstrb
  dma_axi_wlast   <= 1'b1;
  dma_axi_awvalid <= 1'b1;
  dma_axi_wvalid  <= 1'b1;
  dma_axi_bready  <= 1'b1;

  for (k = 0; k < 2000; k++) begin
    @(posedge aclk);

    if (!aw_done && dma_axi_awvalid && dma_axi_awready) begin
      aw_done = 1'b1;
      dma_axi_awvalid <= 1'b0;
    end
    if (!w_done && dma_axi_wvalid && dma_axi_wready) begin
      w_done = 1'b1;
      dma_axi_wvalid <= 1'b0;
    end

    if (aw_done && w_done) break;
  end

  if (!(aw_done && w_done)) begin
    ok = 1'b0;
    $display("[TB][ERR][dma_write_axi] AW/W timeout addr=%08h data=%08h aw_done=%0d w_done=%0d wstrb=%h t=%0t",
             addr, data, aw_done, w_done, dma_axi_wstrb, $time);
    dma_axi_awvalid <= 1'b0;
    dma_axi_wvalid  <= 1'b0;
    return;
  end

  for (k = 0; k < 4000; k++) begin
    @(posedge aclk);
    if (dma_axi_bvalid && dma_axi_bready) begin
      b_done = 1'b1;
      if (dma_axi_bresp != 2'b00) begin
        ok = 1'b0;
        $display("[TB][ERR][dma_write_axi] BRESP error addr=%08h data=%08h bresp=%b id=%02h t=%0t",
                 addr, data, dma_axi_bresp, dma_axi_bid, $time);
      end
      break;
    end
  end

  if (!b_done) begin
    ok = 1'b0;
    $display("[TB][ERR][dma_write_axi] B timeout addr=%08h data=%08h t=%0t", addr, data, $time);
  end
endtask


task automatic dma_read_axi(
  input  [31:0] addr,
  output [31:0] data,
  output bit    ok
);
  int k;
  bit ar_done, r_done;

  ok = 1'b1;
  data = '0;
  ar_done = 1'b0;
  r_done  = 1'b0;

  dma_axi_araddr  <= addr;
  dma_axi_arvalid <= 1'b1;
  dma_axi_rready  <= 1'b1;

  for (k = 0; k < 2000; k++) begin
    @(posedge aclk);
    if (!ar_done && dma_axi_arvalid && dma_axi_arready) begin
      ar_done = 1'b1;
      dma_axi_arvalid <= 1'b0;
      break;
    end
  end

  if (!ar_done) begin
    ok = 1'b0;
    $display("[TB][ERR][dma_read_axi] AR timeout addr=%08h t=%0t", addr, $time);
    dma_axi_arvalid <= 1'b0;
    return;
  end

  for (k = 0; k < 4000; k++) begin
    @(posedge aclk);
    if (dma_axi_rvalid && dma_axi_rready) begin
      data = dma_axi_rdata;
      r_done = 1'b1;
      if (dma_axi_rresp != 2'b00) begin
        ok = 1'b0;
        $display("[TB][ERR][dma_read_axi] RRESP error addr=%08h rresp=%b data=%08h id=%02h t=%0t",
                 addr, dma_axi_rresp, dma_axi_rdata, dma_axi_rid, $time);
      end
      break;
    end
  end

  if (!r_done) begin
    ok = 1'b0;
    $display("[TB][ERR][dma_read_axi] R timeout addr=%08h t=%0t", addr, $time);
  end
endtask

// ===============================
// Add this inside your existing STIMULUS initial block
// (reuse your existing cpu_write_lite/cpu_read_lite/dma_write_axi/dma_read_axi tasks)
// ===============================
initial begin
int case_err;
bit ok;
logic [31:0] rd_cpu, rd_dma;
logic [31:0] final_rd;
int i;

// local helper variables (NO task for print, only $display)
bit cpass;

cpu_lite_wstrb = 4'hF;
dma_axi_wstrb  = 4'hF;

// Make sure DMA defaults are legal before DMA tests
dma_axi_awid    = 8'h20;
dma_axi_arid    = 8'h20;
dma_axi_awlen   = 8'd0;
dma_axi_arlen   = 8'd0;
dma_axi_awsize  = 3'd2;  // 4 bytes
dma_axi_arsize  = 3'd2;  // 4 bytes
dma_axi_awburst = 2'b01; // INCR
dma_axi_arburst = 2'b01; // INCR
dma_axi_wstrb   = 4'hF;
dma_axi_wlast   = 1'b1;
dma_axi_bready  = 1'b1;
dma_axi_rready  = 1'b1;

case_err = 0;

// -------- MUST: wait reset --------
  wait (aresetn === 1'b0);
  wait (aresetn === 1'b1);
  repeat (5) @(posedge aclk);

$display("\n================================================================");
$display("[TB][SUITE] AXI CROSSBAR FULL TEST START @ t=%0t", $time);
$display("================================================================");

$display("[PRE] t=%0t awv=%b wv=%b brdy=%b arv=%b rrdy=%b wstrb=%h",
  $time, cpu_lite_awvalid, cpu_lite_wvalid, cpu_lite_bready, cpu_lite_arvalid, cpu_lite_rready, cpu_lite_wstrb);
// ---------------------------------------------------------
// CASE 01: CPU basic write/read DDR (S0)
// ---------------------------------------------------------
$display("\n[TB][CASE 01] CPU basic DDR write/read");
cpass = 1'b1;

cpu_write_lite(32'h0000_0004, 32'hDEAD_BEEF, ok);
if (!ok) begin
  $display("[TB][ERR][01] CPU write DDR 0x00000004 failed");
  cpass = 1'b0; case_err++;
end else $display("[TB][OK ][01] CPU write DDR 0x00000004");

cpu_read_lite(32'h0000_0004, rd_cpu, ok);
if (!ok || rd_cpu !== 32'hDEAD_BEEF) begin
  $display("[TB][ERR][01] CPU read DDR mismatch rd=%08h exp=DEADBEEF", rd_cpu);
  cpass = 1'b0; case_err++;
end else $display("[TB][OK ][01] CPU read DDR match rd=%08h", rd_cpu);

if (cpass) $display("[TB][PASS][01]");
else       $display("[TB][FAIL][01]");

// ---------------------------------------------------------
// CASE 02: CPU boundary decode on S0/S1
// ---------------------------------------------------------
$display("\n[TB][CASE 02] CPU boundary decode S0 upper / S1 lower");
cpass = 1'b1;

cpu_write_lite(32'h0000_0FFC, 32'h1111_AAAA, ok);
if (!ok) begin
  $display("[TB][ERR][02] CPU write S0 boundary failed");
  cpass = 1'b0; case_err++;
end else $display("[TB][OK ][02] CPU write S0 boundary");

cpu_write_lite(32'h0000_1000, 32'h2222_BBBB, ok);
if (!ok) begin
  $display("[TB][ERR][02] CPU write S1 boundary failed");
  cpass = 1'b0; case_err++;
end else $display("[TB][OK ][02] CPU write S1 boundary");

cpu_read_lite(32'h0000_0FFC, rd_cpu, ok);
if (!ok || rd_cpu !== 32'h1111_AAAA) begin
  $display("[TB][ERR][02] CPU read S0 boundary mismatch rd=%08h", rd_cpu);
  cpass = 1'b0; case_err++;
end else $display("[TB][OK ][02] CPU read S0 boundary match");

cpu_read_lite(32'h0000_1000, rd_cpu, ok);
if (!ok || rd_cpu !== 32'h2222_BBBB) begin
  $display("[TB][ERR][02] CPU read S1 boundary mismatch rd=%08h", rd_cpu);
  cpass = 1'b0; case_err++;
end else $display("[TB][OK ][02] CPU read S1 boundary match");

if (cpass) $display("[TB][PASS][02]");
else       $display("[TB][FAIL][02]");

// ---------------------------------------------------------
// CASE 03: CPU access DMA/NPU registers (S2/S3)
// ---------------------------------------------------------
$display("\n[TB][CASE 03] CPU configure DMA/NPU register models and poll done");
cpass = 1'b1;

// DMA regs
cpu_write_lite(32'h0000_2008, 32'h0000_0010, ok); // SRC
if (!ok) begin $display("[TB][ERR][03] DMA SRC write fail"); cpass=0; case_err++; end
cpu_write_lite(32'h0000_200C, 32'h0000_1010, ok); // DST
if (!ok) begin $display("[TB][ERR][03] DMA DST write fail"); cpass=0; case_err++; end
cpu_write_lite(32'h0000_2010, 32'h0000_0040, ok); // LEN
if (!ok) begin $display("[TB][ERR][03] DMA LEN write fail"); cpass=0; case_err++; end
cpu_write_lite(32'h0000_2000, 32'h0000_0001, ok); // CTRL start
if (!ok) begin $display("[TB][ERR][03] DMA CTRL write fail"); cpass=0; case_err++; end

for (i=0; i<50; i++) begin
  cpu_read_lite(32'h0000_2004, rd_cpu, ok); // STATUS
  if (ok && rd_cpu[1]) begin
    $display("[TB][OK ][03] DMA done observed at poll=%0d status=%08h", i, rd_cpu);
    disable dma_done_poll_break;
  end
  @(posedge aclk);
end
dma_done_poll_break: begin end
if (!(ok && rd_cpu[1])) begin
  $display("[TB][ERR][03] DMA done timeout status=%08h", rd_cpu);
  cpass=0; case_err++;
end

// NPU regs
cpu_write_lite(32'h0000_3010, 32'h0000_0010, ok); // LEN
if (!ok) begin $display("[TB][ERR][03] NPU LEN write fail"); cpass=0; case_err++; end
cpu_write_lite(32'h0000_3000, 32'h0000_0001, ok); // CTRL start
if (!ok) begin $display("[TB][ERR][03] NPU CTRL write fail"); cpass=0; case_err++; end

for (i=0; i<50; i++) begin
  cpu_read_lite(32'h0000_3004, rd_cpu, ok); // STATUS
  if (ok && rd_cpu[1]) begin
    $display("[TB][OK ][03] NPU done observed at poll=%0d status=%08h", i, rd_cpu);
    disable npu_done_poll_break;
  end
  @(posedge aclk);
end
npu_done_poll_break: begin end
if (!(ok && rd_cpu[1])) begin
  $display("[TB][ERR][03] NPU done timeout status=%08h", rd_cpu);
  cpass=0; case_err++;
end

if (cpass) $display("[TB][PASS][03]");
else       $display("[TB][FAIL][03]");

// ---------------------------------------------------------
// CASE 04: illegal address write/read should error
// ---------------------------------------------------------
$display("\n[TB][CASE 04] Illegal address behavior");
cpass = 1'b1;

// write illegal
cpu_write_lite(32'h0000_4000, 32'h1234_5678, ok);
if (ok) begin
  $display("[TB][ERR][04] Illegal WRITE returned OKAY unexpectedly");
  cpass=0; case_err++;
end else $display("[TB][OK ][04] Illegal WRITE returned error as expected");

// read illegal
cpu_read_lite(32'h0000_4000, rd_cpu, ok);
if (ok) begin
  $display("[TB][ERR][04] Illegal READ returned OKAY unexpectedly data=%08h", rd_cpu);
  cpass=0; case_err++;
end else $display("[TB][OK ][04] Illegal READ returned error as expected");

if (cpass) $display("[TB][PASS][04]");
else       $display("[TB][FAIL][04]");

// ---------------------------------------------------------
// CASE 05: DMA basic standalone DDR write/read
// ---------------------------------------------------------
$display("\n[TB][CASE 05] DMA standalone DDR write/read");
cpass = 1'b1;

dma_write_axi(32'h0000_0080, 32'h1234_5678, ok);
if (!ok) begin
  $display("[TB][ERR][05] DMA write DDR failed");
  cpass=0; case_err++;
end else $display("[TB][OK ][05] DMA write DDR");

dma_read_axi(32'h0000_0080, rd_dma, ok);
if (!ok || rd_dma !== 32'h1234_5678) begin
  $display("[TB][ERR][05] DMA read DDR mismatch rd=%08h", rd_dma);
  cpass=0; case_err++;
end else $display("[TB][OK ][05] DMA read DDR match rd=%08h", rd_dma);

if (cpass) $display("[TB][PASS][05]");
else       $display("[TB][FAIL][05]");

// ---------------------------------------------------------
// CASE 06: CPU+DMA concurrent different DDR addresses
// ---------------------------------------------------------
$display("\n[TB][CASE 06] CPU+DMA concurrent write/read different addresses");
cpass = 1'b1;

fork
  begin
    cpu_write_lite(32'h0000_0040, 32'hCAFE_BABE, ok);
    if (!ok) begin $display("[TB][ERR][06] CPU concurrent write fail"); cpass=0; case_err++; end
    cpu_read_lite(32'h0000_0040, rd_cpu, ok);
    if (!ok || rd_cpu !== 32'hCAFE_BABE) begin
      $display("[TB][ERR][06] CPU concurrent readback mismatch rd=%08h", rd_cpu);
      cpass=0; case_err++;
    end
  end
  begin
    dma_write_axi(32'h0000_0080, 32'h89AB_CDEF, ok);
    if (!ok) begin $display("[TB][ERR][06] DMA concurrent write fail"); cpass=0; case_err++; end
    dma_read_axi(32'h0000_0080, rd_dma, ok);
    if (!ok || rd_dma !== 32'h89AB_CDEF) begin
      $display("[TB][ERR][06] DMA concurrent readback mismatch rd=%08h", rd_dma);
      cpass=0; case_err++;
    end
  end
join

if (cpass) $display("[TB][PASS][06]");
else       $display("[TB][FAIL][06]");

// ---------------------------------------------------------
// CASE 07: CPU+DMA same address conflict (ordering visibility)
// ---------------------------------------------------------
$display("\n[TB][CASE 07] CPU+DMA same-address conflict (no deadlock, deterministic completion)");
cpass = 1'b1;

// initialize location
cpu_write_lite(32'h0000_0100, 32'h0000_0000, ok);
if (!ok) begin $display("[TB][ERR][07] pre-init write fail"); cpass=0; case_err++; end

fork
  begin
    cpu_write_lite(32'h0000_0100, 32'hAAAA_AAAA, ok);
    if (!ok) begin $display("[TB][ERR][07] CPU same-addr write fail"); cpass=0; case_err++; end
  end
  begin
    dma_write_axi(32'h0000_0100, 32'h5555_5555, ok);
    if (!ok) begin $display("[TB][ERR][07] DMA same-addr write fail"); cpass=0; case_err++; end
  end
join

cpu_read_lite(32'h0000_0100, final_rd, ok);
if (!ok) begin
  $display("[TB][ERR][07] final read fail");
  cpass=0; case_err++;
end else begin
  if (final_rd !== 32'hAAAA_AAAA && final_rd !== 32'h5555_5555) begin
    $display("[TB][ERR][07] final data invalid rd=%08h (expect one of writers)", final_rd);
    cpass=0; case_err++;
  end else begin
    $display("[TB][OK ][07] final data=%08h (one-writer wins as expected)", final_rd);
  end
end

if (cpass) $display("[TB][PASS][07]");
else       $display("[TB][FAIL][07]");

// ---------------------------------------------------------
// CASE 08: WSTRB partial write check on DDR
// ---------------------------------------------------------
$display("\n[TB][CASE 08] WSTRB partial write on DDR");
cpass = 1'b1;

// full write baseline
cpu_write_lite(32'h0000_0120, 32'h1122_3344, ok);
if (!ok) begin $display("[TB][ERR][08] baseline write fail"); cpass=0; case_err++; end

// use DMA partial byte write: update high byte only -> xx22_3344 becomes AA22_3344
dma_axi_wstrb <= 4'b1000;
dma_write_axi(32'h0000_0120, 32'hAA00_0000, ok);
dma_axi_wstrb <= 4'hF;

if (!ok) begin $display("[TB][ERR][08] partial write fail"); cpass=0; case_err++; end

cpu_read_lite(32'h0000_0120, rd_cpu, ok);
if (!ok || rd_cpu !== 32'hAA22_3344) begin
  $display("[TB][ERR][08] partial write mismatch rd=%08h exp=AA223344", rd_cpu);
  cpass=0; case_err++;
end else $display("[TB][OK ][08] partial write match rd=%08h", rd_cpu);

if (cpass) $display("[TB][PASS][08]");
else       $display("[TB][FAIL][08]");

// ---------------------------------------------------------
// CASE 09: simple stress random accesses (CPU only)
// ---------------------------------------------------------
$display("\n[TB][CASE 09] CPU random stress (DDR/NPU_LMEM)");
cpass = 1'b1;

for (i=0; i<100; i++) begin
  logic [31:0] a;
  logic [31:0] d;
  a = (i[0]) ? (32'h0000_0000 + ((i*4) & 32'h00000FFC)) // DDR
             : (32'h0000_1000 + ((i*4) & 32'h00000FFC)); // NPU_LMEM
  d = 32'hA5A50000 ^ i;
  cpu_write_lite(a, d, ok);
  if (!ok) begin
    $display("[TB][ERR][09] write fail i=%0d addr=%08h", i, a);
    cpass=0; case_err++;
  end
  cpu_read_lite(a, rd_cpu, ok);
  if (!ok || rd_cpu !== d) begin
    $display("[TB][ERR][09] read mismatch i=%0d addr=%08h rd=%08h exp=%08h", i, a, rd_cpu, d);
    cpass=0; case_err++;
  end
end

if (cpass) $display("[TB][PASS][09]");
else       $display("[TB][FAIL][09]");

// ===============================
// SUITE SUMMARY
// ===============================
$display("\n================================================================");
if (case_err == 0) begin
  $display("[TB][SUITE PASS] ALL CASES PASSED");
end else begin
  $display("[TB][SUITE FAIL] error_count=%0d", case_err);
end
$display("================================================================\n");

    repeat (20) @(posedge aclk);
    $stop;

  end

endmodule

`default_nettype wire