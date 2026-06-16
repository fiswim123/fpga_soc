`timescale 1ns/1ps
`default_nettype none

`include "../src/dma/inc/amba_axi.svh"
`include "../src/dma/inc/dma_pkg.svh"

module soc_tb;
  import amba_axi_pkg::*;
  import dma_utils_pkg::*;

  // ==========================================================
  // 参数定义
  // ==========================================================
  localparam int AXI_ADDR_W = 32;
  localparam int AXI_DATA_W = 32;
  localparam int AXI_ID_W   = 8;

  parameter [8*128-1:0] LOCAL_ROM_INIT_FILE = "../src/instr_data.dat";
  //parameter [8*128-1:0] DDR_INIT_FILE = "../src/mnist.hex";
  parameter [8*128-1:0] DDR_INIT_FILE = "";

// CPU 本地存储器（不经过 AXI 总线）
localparam logic [31:0] CPU_ROM_BASE = 32'h0000_0000;
localparam int          CPU_ROM_AW   = 12;   // 4KB
localparam logic [31:0] CPU_RAM_BASE = 32'h1000_0000;
localparam int          CPU_RAM_AW   = 12;   // 4KB

// 系统总线地址映射（用于 AXI Crossbar）
localparam logic [31:0] NPU_LMEM_BASE = 32'h0000_1000;
localparam int          NPU_LMEM_SIZE_BYTES = 131072;   // 128KB
localparam logic [31:0] NPU_LMEM_MASK = 32'hFFFF_0000;  // 128KB 对齐

localparam logic [31:0] NPU_CSR_BASE = 32'h0002_0000;
localparam int          NPU_CSR_SIZE_BYTES = 4096;
localparam logic [31:0] NPU_CSR_MASK = 32'hFFFF_F000;

localparam logic [31:0] DMA_CSR_BASE = 32'h0002_1000;
localparam int          DMA_CSR_SIZE_BYTES = 4096;
localparam logic [31:0] DMA_CSR_MASK = 32'hFFFF_F000;

localparam logic [31:0] DDR_BASE = 32'h4000_0000;
localparam int          DDR_SIZE_BYTES = 64 * 1024 * 1024;
localparam logic [31:0] DDR_MASK = 32'hFC00_0000;

  // 时钟与复位
  logic clk, rst, resetn;
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end
  initial begin
    rst = 1'b1;
    #100 rst = 1'b0;
  end
  assign resetn = ~rst;

  // ==========================================================
  // CPU AXI4-Lite 接口 (直接连接至桥)
  // ==========================================================
  logic        cpu_lite_awvalid, cpu_lite_awready;
  logic [31:0] cpu_lite_awaddr;
  logic [2:0]  cpu_lite_awprot;
  logic        cpu_lite_wvalid, cpu_lite_wready;
  logic [31:0] cpu_lite_wdata;
  logic [3:0]  cpu_lite_wstrb;
  logic        cpu_lite_bvalid, cpu_lite_bready;
  logic [1:0]  cpu_lite_bresp;
  logic        cpu_lite_arvalid, cpu_lite_arready;
  logic [31:0] cpu_lite_araddr;
  logic [2:0]  cpu_lite_arprot;
  logic        cpu_lite_rvalid, cpu_lite_rready;
  logic [31:0] cpu_lite_rdata;
  logic [1:0]  cpu_lite_rresp;

  logic cpu_trap;

  logic        pcpi_wr, pcpi_wait, pcpi_ready;
  logic [31:0] pcpi_rd, irq, eoi;
  logic        trace_valid, pcpi_valid;
  logic [35:0] trace_data;
  logic [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2;
  assign pcpi_wr=0; assign pcpi_rd=0; assign pcpi_wait=0; assign pcpi_ready=0; assign irq=0;

  // CPU 经过桥接后的 AXI4 接口 (连接到 crossbar slv0)
  logic [AXI_ID_W-1:0]   cpu_axi_awid;
  logic [AXI_ADDR_W-1:0] cpu_axi_awaddr;
  logic [7:0]            cpu_axi_awlen;
  logic [2:0]            cpu_axi_awsize;
  logic [1:0]            cpu_axi_awburst;
  logic                  cpu_axi_awlock;
  logic [3:0]            cpu_axi_awcache;
  logic [2:0]            cpu_axi_awprot;
  logic [3:0]            cpu_axi_awqos;
  logic [3:0]            cpu_axi_awregion;
  logic                  cpu_axi_awvalid;
  logic                  cpu_axi_awready;
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
  logic                  cpu_axi_arlock;
  logic [3:0]            cpu_axi_arcache;
  logic [2:0]            cpu_axi_arprot;
  logic [3:0]            cpu_axi_arqos;
  logic [3:0]            cpu_axi_arregion;
  logic                  cpu_axi_arvalid;
  logic                  cpu_axi_arready;
  logic [AXI_ID_W-1:0]   cpu_axi_rid;
  logic [AXI_DATA_W-1:0] cpu_axi_rdata;
  logic [1:0]            cpu_axi_rresp;
  logic                  cpu_axi_rlast;
  logic                  cpu_axi_rvalid;
  logic                  cpu_axi_rready;


  // ==========================================================
// DMA 模块接口
// ==========================================================

// DMA 的 AXI4-Lite 从接口 (连接至 crossbar mst2 经过桥)
logic        dma_csr_awvalid, dma_csr_awready;
logic [31:0] dma_csr_awaddr;
//logic [2:0]  dma_csr_awprot;
logic        dma_csr_wvalid, dma_csr_wready;
logic [31:0] dma_csr_wdata;
logic [3:0]  dma_csr_wstrb;
logic        dma_csr_bvalid, dma_csr_bready;
logic [1:0]  dma_csr_bresp;
logic        dma_csr_arvalid, dma_csr_arready;
logic [31:0] dma_csr_araddr;
//logic [2:0]  dma_csr_arprot;
logic        dma_csr_rvalid, dma_csr_rready;
logic [31:0] dma_csr_rdata;
logic [1:0]  dma_csr_rresp;

// DMA 的 AXI4 主接口 (连接到 crossbar slv1)
// 写地址通道
logic [AXI_ID_W-1:0]   dma_axi_awid;
logic [AXI_ADDR_W-1:0] dma_axi_awaddr;
logic [7:0]            dma_axi_awlen;
logic [2:0]            dma_axi_awsize;
logic [1:0]            dma_axi_awburst;
logic                  dma_axi_awlock;
logic [3:0]            dma_axi_awcache;
logic [2:0]            dma_axi_awprot;
logic [3:0]            dma_axi_awqos;
logic [3:0]            dma_axi_awregion;
logic                  dma_axi_awuser;
logic                  dma_axi_awvalid;
logic                  dma_axi_awready;

// 写数据通道
logic [AXI_DATA_W-1:0]     dma_axi_wdata;
logic [AXI_DATA_W/8-1:0]   dma_axi_wstrb;
logic                      dma_axi_wlast;
logic                      dma_axi_wuser;
logic                      dma_axi_wvalid;
logic                      dma_axi_wready;

// 写响应通道
logic [AXI_ID_W-1:0]   dma_axi_bid;
//logic [1:0]            dma_axi_bresp;
logic                  dma_axi_buser;
logic                  dma_axi_bvalid;
logic                  dma_axi_bready;

// 读地址通道
logic [AXI_ID_W-1:0]   dma_axi_arid;
logic [AXI_ADDR_W-1:0] dma_axi_araddr;
logic [7:0]            dma_axi_arlen;
logic [2:0]            dma_axi_arsize;
logic [1:0]            dma_axi_arburst;
logic                  dma_axi_arlock;
logic [3:0]            dma_axi_arcache;
logic [2:0]            dma_axi_arprot;
logic [3:0]            dma_axi_arqos;
logic [3:0]            dma_axi_arregion;
logic                  dma_axi_aruser;
logic                  dma_axi_arvalid;
logic                  dma_axi_arready;

// 读数据通道
logic [AXI_ID_W-1:0]   dma_axi_rid;
logic [AXI_DATA_W-1:0] dma_axi_rdata;
//logic [1:0]            dma_axi_rresp;
logic                  dma_axi_rlast;
logic                  dma_axi_ruser;
logic                  dma_axi_rvalid;
logic                  dma_axi_rready;

// ===== 使用包类型 =====
axi_prot_t dma_csr_awprot;
axi_prot_t dma_csr_arprot;
axi_resp_t dma_axi_bresp;
axi_resp_t dma_axi_rresp;

// ===== 新增：crossbar 边界桥接信号（plain logic）=====
logic [2:0] dma_csr_awprot_xbar;
logic [2:0] dma_csr_arprot_xbar;
wire [1:0] dma_axi_bresp_xbar;
wire [1:0] dma_axi_rresp_xbar;

// DMA 状态信号
logic dma_done, dma_error;

  // ==========================================================
  // Crossbar 从设备端接口 (连接至实际从设备)
  // ==========================================================
  // mst0 -> DDR
  logic                  xbar_mst0_awvalid, xbar_mst0_awready;
  logic [AXI_ADDR_W-1:0] xbar_mst0_awaddr;
  logic [7:0]            xbar_mst0_awlen;
  logic [2:0]            xbar_mst0_awsize;
  logic [1:0]            xbar_mst0_awburst;
  logic                  xbar_mst0_awlock;
  logic [3:0]            xbar_mst0_awcache;
  logic [2:0]            xbar_mst0_awprot;
  logic [3:0]            xbar_mst0_awqos;
  logic [3:0]            xbar_mst0_awregion;
  logic [AXI_ID_W-1:0]   xbar_mst0_awid;
  logic                  xbar_mst0_wvalid, xbar_mst0_wready;
  logic [AXI_DATA_W-1:0] xbar_mst0_wdata;
  logic [AXI_DATA_W/8-1:0] xbar_mst0_wstrb;
  logic                  xbar_mst0_wlast;
  logic                  xbar_mst0_bvalid, xbar_mst0_bready;
  logic [AXI_ID_W-1:0]   xbar_mst0_bid;
  logic [1:0]            xbar_mst0_bresp;
  logic                  xbar_mst0_arvalid, xbar_mst0_arready;
  logic [AXI_ADDR_W-1:0] xbar_mst0_araddr;
  logic [7:0]            xbar_mst0_arlen;
  logic [2:0]            xbar_mst0_arsize;
  logic [1:0]            xbar_mst0_arburst;
  logic                  xbar_mst0_arlock;
  logic [3:0]            xbar_mst0_arcache;
  logic [2:0]            xbar_mst0_arprot;
  logic [3:0]            xbar_mst0_arqos;
  logic [3:0]            xbar_mst0_arregion;
  logic [AXI_ID_W-1:0]   xbar_mst0_arid;
  logic                  xbar_mst0_rvalid, xbar_mst0_rready;
  logic [AXI_ID_W-1:0]   xbar_mst0_rid;
  logic [1:0]            xbar_mst0_rresp;
  logic [AXI_DATA_W-1:0] xbar_mst0_rdata;
  logic                  xbar_mst0_rlast;

  // mst1 -> NPU LMEM
  logic                  xbar_mst1_awvalid, xbar_mst1_awready;
  logic [AXI_ADDR_W-1:0] xbar_mst1_awaddr;
  logic [7:0]            xbar_mst1_awlen;
  logic [2:0]            xbar_mst1_awsize;
  logic [1:0]            xbar_mst1_awburst;
  logic                  xbar_mst1_awlock;
  logic [3:0]            xbar_mst1_awcache;
  logic [2:0]            xbar_mst1_awprot;
  logic [3:0]            xbar_mst1_awqos;
  logic [3:0]            xbar_mst1_awregion;
  logic [AXI_ID_W-1:0]   xbar_mst1_awid;
  logic                  xbar_mst1_wvalid, xbar_mst1_wready;
  logic [AXI_DATA_W-1:0] xbar_mst1_wdata;
  logic [AXI_DATA_W/8-1:0] xbar_mst1_wstrb;
  logic                  xbar_mst1_wlast;
  logic                  xbar_mst1_bvalid, xbar_mst1_bready;
  logic [AXI_ID_W-1:0]   xbar_mst1_bid;
  logic [1:0]            xbar_mst1_bresp;
  logic                  xbar_mst1_arvalid, xbar_mst1_arready;
  logic [AXI_ADDR_W-1:0] xbar_mst1_araddr;
  logic [7:0]            xbar_mst1_arlen;
  logic [2:0]            xbar_mst1_arsize;
  logic [1:0]            xbar_mst1_arburst;
  logic                  xbar_mst1_arlock;
  logic [3:0]            xbar_mst1_arcache;
  logic [2:0]            xbar_mst1_arprot;
  logic [3:0]            xbar_mst1_arqos;
  logic [3:0]            xbar_mst1_arregion;
  logic [AXI_ID_W-1:0]   xbar_mst1_arid;
  logic                  xbar_mst1_rvalid, xbar_mst1_rready;
  logic [AXI_ID_W-1:0]   xbar_mst1_rid;
  logic [1:0]            xbar_mst1_rresp;
  logic [AXI_DATA_W-1:0] xbar_mst1_rdata;
  logic                  xbar_mst1_rlast;

  // mst2 -> DMA CSR (经过 AXI4->AXI4-Lite 桥)
  logic                  xbar_mst2_awvalid, xbar_mst2_awready;
  logic [AXI_ADDR_W-1:0] xbar_mst2_awaddr;
  logic [7:0]            xbar_mst2_awlen;
  logic [2:0]            xbar_mst2_awsize;
  logic [1:0]            xbar_mst2_awburst;
  logic                  xbar_mst2_awlock;
  logic [3:0]            xbar_mst2_awcache;
  logic [2:0]            xbar_mst2_awprot;
  logic [3:0]            xbar_mst2_awqos;
  logic [3:0]            xbar_mst2_awregion;
  logic [AXI_ID_W-1:0]   xbar_mst2_awid;
  logic                  xbar_mst2_wvalid, xbar_mst2_wready;
  logic [AXI_DATA_W-1:0] xbar_mst2_wdata;
  logic [AXI_DATA_W/8-1:0] xbar_mst2_wstrb;
  logic                  xbar_mst2_wlast;
  logic                  xbar_mst2_bvalid, xbar_mst2_bready;
  logic [AXI_ID_W-1:0]   xbar_mst2_bid;
  logic [1:0]            xbar_mst2_bresp;
  logic                  xbar_mst2_arvalid, xbar_mst2_arready;
  logic [AXI_ADDR_W-1:0] xbar_mst2_araddr;
  logic [7:0]            xbar_mst2_arlen;
  logic [2:0]            xbar_mst2_arsize;
  logic [1:0]            xbar_mst2_arburst;
  logic                  xbar_mst2_arlock;
  logic [3:0]            xbar_mst2_arcache;
  logic [2:0]            xbar_mst2_arprot;
  logic [3:0]            xbar_mst2_arqos;
  logic [3:0]            xbar_mst2_arregion;
  logic [AXI_ID_W-1:0]   xbar_mst2_arid;
  logic                  xbar_mst2_rvalid, xbar_mst2_rready;
  logic [AXI_ID_W-1:0]   xbar_mst2_rid;
  logic [1:0]            xbar_mst2_rresp;
  logic [AXI_DATA_W-1:0] xbar_mst2_rdata;
  logic                  xbar_mst2_rlast;

  // mst3 -> NPU Registers
  logic                  xbar_mst3_awvalid, xbar_mst3_awready;
  logic [AXI_ADDR_W-1:0] xbar_mst3_awaddr;
  logic [7:0]            xbar_mst3_awlen;
  logic [2:0]            xbar_mst3_awsize;
  logic [1:0]            xbar_mst3_awburst;
  logic                  xbar_mst3_awlock;
  logic [3:0]            xbar_mst3_awcache;
  logic [2:0]            xbar_mst3_awprot;
  logic [3:0]            xbar_mst3_awqos;
  logic [3:0]            xbar_mst3_awregion;
  logic [AXI_ID_W-1:0]   xbar_mst3_awid;
  logic                  xbar_mst3_wvalid, xbar_mst3_wready;
  logic [AXI_DATA_W-1:0] xbar_mst3_wdata;
  logic [AXI_DATA_W/8-1:0] xbar_mst3_wstrb;
  logic                  xbar_mst3_wlast;
  logic                  xbar_mst3_bvalid, xbar_mst3_bready;
  logic [AXI_ID_W-1:0]   xbar_mst3_bid;
  logic [1:0]            xbar_mst3_bresp;
  logic                  xbar_mst3_arvalid, xbar_mst3_arready;
  logic [AXI_ADDR_W-1:0] xbar_mst3_araddr;
  logic [7:0]            xbar_mst3_arlen;
  logic [2:0]            xbar_mst3_arsize;
  logic [1:0]            xbar_mst3_arburst;
  logic                  xbar_mst3_arlock;
  logic [3:0]            xbar_mst3_arcache;
  logic [2:0]            xbar_mst3_arprot;
  logic [3:0]            xbar_mst3_arqos;
  logic [3:0]            xbar_mst3_arregion;
  logic [AXI_ID_W-1:0]   xbar_mst3_arid;
  logic                  xbar_mst3_rvalid, xbar_mst3_rready;
  logic [AXI_ID_W-1:0]   xbar_mst3_rid;
  logic [1:0]            xbar_mst3_rresp;
  logic [AXI_DATA_W-1:0] xbar_mst3_rdata;
  logic                  xbar_mst3_rlast;

  // ==========================================================
  // 实例化 CPU (PicoRV32 with AXI4-Lite)
  // ==========================================================
  // 注意：picorv32_axi 的 mem_axi 接口是 AXI4-Lite，因此直接连接到桥的 AXI4-Lite 端
  picorv32_axi #(
    .ENABLE_TRACE         (1),
    .PROGADDR_RESET       (32'h0000_0000),
    .PROGADDR_IRQ         (32'h0000_0010),
    .LOCAL_ROM_BASE       (CPU_ROM_BASE),
    .LOCAL_ROM_ADDR_WIDTH (CPU_ROM_AW),
    .LOCAL_RAM_BASE       (CPU_RAM_BASE),
    .LOCAL_RAM_ADDR_WIDTH (CPU_RAM_AW),
    .LOCAL_ROM_INIT_FILE  (LOCAL_ROM_INIT_FILE)
  ) u_cpu (
    .clk(clk),
    .resetn(resetn),
    .trap(cpu_trap),
    .mem_axi_awvalid(cpu_lite_awvalid),
    .mem_axi_awready(cpu_lite_awready),
    .mem_axi_awaddr(cpu_lite_awaddr),
    .mem_axi_awprot(cpu_lite_awprot),
    .mem_axi_wvalid(cpu_lite_wvalid),
    .mem_axi_wready(cpu_lite_wready),
    .mem_axi_wdata(cpu_lite_wdata),
    .mem_axi_wstrb(cpu_lite_wstrb),
    .mem_axi_bvalid(cpu_lite_bvalid),
    .mem_axi_bready(cpu_lite_bready),
    .mem_axi_arvalid(cpu_lite_arvalid),
    .mem_axi_arready(cpu_lite_arready),
    .mem_axi_araddr(cpu_lite_araddr),
    .mem_axi_arprot(cpu_lite_arprot),
    .mem_axi_rvalid(cpu_lite_rvalid),
    .mem_axi_rready(cpu_lite_rready),
    .mem_axi_rdata(cpu_lite_rdata),
    .pcpi_valid(pcpi_valid), .pcpi_insn(pcpi_insn), .pcpi_rs1(pcpi_rs1), .pcpi_rs2(pcpi_rs2),
    .pcpi_wr(pcpi_wr), .pcpi_rd(pcpi_rd), .pcpi_wait(pcpi_wait), .pcpi_ready(pcpi_ready),
    .irq(irq), .eoi(eoi), .trace_valid(trace_valid), .trace_data(trace_data)
  );

  // AXI4-Lite to AXI4 桥 (将 CPU 的 AXI4-Lite 转为 AXI4 连接到 crossbar)
  axi_lite2axi #(
    .DATA_WIDTH(AXI_DATA_W),
    .ADDR_WIDTH(AXI_ADDR_W),
    .ID_WIDTH(AXI_ID_W)
  ) u_cpu_bridge (
    .aclk(clk),
    .aresetn(resetn),
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
    .m_axi_wid(),
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

  // ==========================================================
// 实例化 DMA 模块 (dma_axi_top)
// ==========================================================
// 说明：
//   - 保留 AXI4 → AXI4-Lite 桥接逻辑（将 crossbar mst2 转换为 DMA CSR 所需的 AXI4-Lite）
//   - DMA 主接口（AXI4）直接连接到 crossbar 的 slv1
//   - 所有信号命名沿用原有定义（dma_csr_* 和 dma_axi_*）

dma_axi_top u_dma (
    .clk(clk),
    .rst(rst),

    // DMA 状态输出
    .dma_done_o(dma_done),
    .dma_error_o(dma_error),

    // -------- Slave AXI4-Lite 接口（来自桥接逻辑）--------
    .dma_s_awaddr  (dma_csr_awaddr),
    .dma_s_awprot  (dma_csr_awprot),
    .dma_s_awvalid (dma_csr_awvalid),
    .dma_s_awready (dma_csr_awready),
    .dma_s_wdata   (dma_csr_wdata),
    .dma_s_wstrb   (dma_csr_wstrb),
    .dma_s_wvalid  (dma_csr_wvalid),
    .dma_s_wready  (dma_csr_wready),
    .dma_s_bresp   (dma_csr_bresp),
    .dma_s_bvalid  (dma_csr_bvalid),
    .dma_s_bready  (dma_csr_bready),
    .dma_s_araddr  (dma_csr_araddr),
    .dma_s_arprot  (dma_csr_arprot),
    .dma_s_arvalid (dma_csr_arvalid),
    .dma_s_arready (dma_csr_arready),
    .dma_s_rdata   (dma_csr_rdata),
    .dma_s_rresp   (dma_csr_rresp),
    .dma_s_rvalid  (dma_csr_rvalid),
    .dma_s_rready  (dma_csr_rready),
    .dma_s_wlast   (1'b1),               // AXI4-Lite 固定为 1
    .dma_s_rlast   (),                   // 输出，悬空

    // -------- Master AXI4 接口（连接到 crossbar slv1）--------
    .dma_m_awid     (dma_axi_awid),
    .dma_m_awaddr   (dma_axi_awaddr),
    .dma_m_awlen    (dma_axi_awlen),
    .dma_m_awsize   (dma_axi_awsize),
    .dma_m_awburst  (dma_axi_awburst),
    .dma_m_awlock   (dma_axi_awlock),
    .dma_m_awcache  (dma_axi_awcache),
    .dma_m_awprot   (dma_axi_awprot),
    .dma_m_awqos    (dma_axi_awqos),
    .dma_m_awregion (dma_axi_awregion),
    .dma_m_awuser   (dma_axi_awuser),
    .dma_m_awvalid  (dma_axi_awvalid),
    .dma_m_awready  (dma_axi_awready),

    .dma_m_wdata    (dma_axi_wdata),
    .dma_m_wstrb    (dma_axi_wstrb),
    .dma_m_wlast    (dma_axi_wlast),
    .dma_m_wuser    (dma_axi_wuser),
    .dma_m_wvalid   (dma_axi_wvalid),
    .dma_m_wready   (dma_axi_wready),

    .dma_m_bid      (dma_axi_bid),
    .dma_m_bresp    (dma_axi_bresp),
    .dma_m_buser    (dma_axi_buser),
    .dma_m_bvalid   (dma_axi_bvalid),
    .dma_m_bready   (dma_axi_bready),

    .dma_m_arid     (dma_axi_arid),
    .dma_m_araddr   (dma_axi_araddr),
    .dma_m_arlen    (dma_axi_arlen),
    .dma_m_arsize   (dma_axi_arsize),
    .dma_m_arburst  (dma_axi_arburst),
    .dma_m_arlock   (dma_axi_arlock),
    .dma_m_arcache  (dma_axi_arcache),
    .dma_m_arprot   (dma_axi_arprot),
    .dma_m_arqos    (dma_axi_arqos),
    .dma_m_arregion (dma_axi_arregion),
    .dma_m_aruser   (dma_axi_aruser),
    .dma_m_arvalid  (dma_axi_arvalid),
    .dma_m_arready  (dma_axi_arready),

    .dma_m_rid      (dma_axi_rid),
    .dma_m_rdata    (dma_axi_rdata),
    .dma_m_rresp    (dma_axi_rresp),
    .dma_m_rlast    (dma_axi_rlast),
    .dma_m_ruser    (dma_axi_ruser),
    .dma_m_rvalid   (dma_axi_rvalid),
    .dma_m_rready   (dma_axi_rready)
);

// ==========================================================
// AXI4 -> AXI4-Lite 桥（用于 DMA CSR，必须保留）
// ==========================================================
// 将 crossbar mst2 的 AXI4 请求转换为 AXI4-Lite 连接到 dma_csr_*

// ---------------------------------------------
// ID return fix for xbar mst2 <-> dma csr lite bridge
// ---------------------------------------------
logic [AXI_ID_W-1:0] mst2_wr_id_q, mst2_rd_id_q;

always_ff @(posedge clk or negedge resetn) begin
  if (!resetn) begin
    mst2_wr_id_q <= '0;
    mst2_rd_id_q <= '0;
  end else begin
    // latch write transaction ID when AW handshake
    if (xbar_mst2_awvalid && xbar_mst2_awready)
      mst2_wr_id_q <= xbar_mst2_awid;

    // latch read transaction ID when AR handshake
    if (xbar_mst2_arvalid && xbar_mst2_arready)
      mst2_rd_id_q <= xbar_mst2_arid;
  end
end

always_comb begin
    // 输入来自 crossbar mst2
    dma_csr_awvalid = xbar_mst2_awvalid && (xbar_mst2_awlen == 8'd0) && (xbar_mst2_awsize == 3'd2);
    dma_csr_awaddr  = xbar_mst2_awaddr;
    dma_csr_wvalid  = xbar_mst2_wvalid;
    dma_csr_wdata   = xbar_mst2_wdata;
    dma_csr_wstrb   = xbar_mst2_wstrb;
    dma_csr_bready  = xbar_mst2_bready;
    dma_csr_arvalid = xbar_mst2_arvalid && (xbar_mst2_arlen == 8'd0) && (xbar_mst2_arsize == 3'd2);
    dma_csr_araddr  = xbar_mst2_araddr;
    dma_csr_rready  = xbar_mst2_rready;

    // prot：先用 logic 承接，再转成 typed enum
    dma_csr_awprot_xbar = xbar_mst2_awprot;
    dma_csr_arprot_xbar = xbar_mst2_arprot;
    dma_csr_awprot      = axi_prot_t'(dma_csr_awprot_xbar);
    dma_csr_arprot      = axi_prot_t'(dma_csr_arprot_xbar);

    // 输出到 crossbar mst2
    xbar_mst2_awready = dma_csr_awready;
    xbar_mst2_wready  = dma_csr_wready;
    xbar_mst2_bvalid  = dma_csr_bvalid;
    xbar_mst2_bresp   = dma_csr_bresp;
    xbar_mst2_arready = dma_csr_arready;
    xbar_mst2_rvalid  = dma_csr_rvalid;
    xbar_mst2_rdata   = dma_csr_rdata;
    xbar_mst2_rresp   = dma_csr_rresp;

    // 返回给crossbar的响应ID必须与请求ID一致
    xbar_mst2_bid   = mst2_wr_id_q;
    xbar_mst2_rid   = mst2_rd_id_q;
    xbar_mst2_rlast = 1'b1;
end

always_comb begin
  dma_axi_bresp = axi_resp_t'(dma_axi_bresp_xbar);
  dma_axi_rresp = axi_resp_t'(dma_axi_rresp_xbar);
end

  // ==========================================================
  // AXI Crossbar (axicb_crossbar_top)
  // ==========================================================
  axicb_crossbar_top #(
    .AXI_ADDR_W(AXI_ADDR_W),
    .AXI_ID_W(AXI_ID_W),
    .AXI_DATA_W(AXI_DATA_W),
    .MST_NB(4),                  // 4 个 master 端口 (连接从设备)
    .SLV_NB(4),                  // 4 个 slave 端口 (连接主设备)
    .MST_PIPELINE(0),
    .SLV_PIPELINE(0),
    .AXI_SIGNALING(1),
    .USER_SUPPORT(0),
    .TIMEOUT_ENABLE(0),

    // 主设备 0: CPU (ID mask 0x10)
    .MST0_CDC(0), .MST0_OSTDREQ_NUM(4), .MST0_OSTDREQ_SIZE(1), .MST0_PRIORITY(0),
    .MST0_ROUTES(4'b1111), .MST0_ID_MASK(8'h10),

    // 主设备 1: DMA (ID mask 0x20)
    .MST1_CDC(0), .MST1_OSTDREQ_NUM(4), .MST1_OSTDREQ_SIZE(1), .MST1_PRIORITY(0),
    .MST1_ROUTES(4'b1111), .MST1_ID_MASK(8'h20),

    // 主设备 2/3 未使用
    .MST2_CDC(0), .MST2_OSTDREQ_NUM(1), .MST2_OSTDREQ_SIZE(1), .MST2_PRIORITY(0),
    .MST2_ROUTES(4'b0000), .MST2_ID_MASK(8'h30),
    .MST3_CDC(0), .MST3_OSTDREQ_NUM(1), .MST3_OSTDREQ_SIZE(1), .MST3_PRIORITY(0),
    .MST3_ROUTES(4'b0000), .MST3_ID_MASK(8'h40),

    // 从设备 0: DDR (0x4000_0000 - 0x43FF_FFFF)
    .SLV0_CDC(0), .SLV0_START_ADDR(32'h4000_0000), .SLV0_END_ADDR(32'h43FF_FFFF),
    .SLV0_OSTDREQ_NUM(4), .SLV0_OSTDREQ_SIZE(1), .SLV0_KEEP_BASE_ADDR(0),

    // 从设备 1: NPU LMEM (0x0000_1000 - 0x0002_0FFF)
    .SLV1_CDC(0), .SLV1_START_ADDR(32'h0000_1000), .SLV1_END_ADDR(32'h0002_0FFF),
    .SLV1_OSTDREQ_NUM(4), .SLV1_OSTDREQ_SIZE(1), .SLV1_KEEP_BASE_ADDR(0),

    // 从设备 2: DMA CSR (0x0002_1000 - 0x0002_1FFF)
    .SLV2_CDC(0), .SLV2_START_ADDR(32'h0002_1000), .SLV2_END_ADDR(32'h0002_1FFF),
    .SLV2_OSTDREQ_NUM(4), .SLV2_OSTDREQ_SIZE(1), .SLV2_KEEP_BASE_ADDR(0),

    // 从设备 3: NPU REG (0x0002_0000 - 0x0002_0FFF)
    .SLV3_CDC(0), .SLV3_START_ADDR(32'h0002_0000), .SLV3_END_ADDR(32'h0002_0FFF),
    .SLV3_OSTDREQ_NUM(4), .SLV3_OSTDREQ_SIZE(1), .SLV3_KEEP_BASE_ADDR(0)
  ) u_crossbar (
    .aclk(clk),
    .aresetn(resetn),
    .srst(rst),

    // Slave 0: CPU master
    .slv0_aclk(clk), .slv0_aresetn(resetn), .slv0_srst(rst),
    .slv0_awvalid(cpu_axi_awvalid), .slv0_awready(cpu_axi_awready),
    .slv0_awaddr(cpu_axi_awaddr), .slv0_awlen(cpu_axi_awlen), .slv0_awsize(cpu_axi_awsize),
    .slv0_awburst(cpu_axi_awburst), .slv0_awlock(1'b0), .slv0_awcache(4'b0),
    .slv0_awprot(cpu_axi_awprot), .slv0_awqos(4'b0), .slv0_awregion(4'b0),
    .slv0_awid(cpu_axi_awid), .slv0_awuser(1'b0),
    .slv0_wvalid(cpu_axi_wvalid), .slv0_wready(cpu_axi_wready),
    .slv0_wlast(cpu_axi_wlast), .slv0_wdata(cpu_axi_wdata), .slv0_wstrb(cpu_axi_wstrb),
    .slv0_wuser(1'b0),
    .slv0_bvalid(cpu_axi_bvalid), .slv0_bready(cpu_axi_bready),
    .slv0_bid(cpu_axi_bid), .slv0_bresp(cpu_axi_bresp), .slv0_buser(),
    .slv0_arvalid(cpu_axi_arvalid), .slv0_arready(cpu_axi_arready),
    .slv0_araddr(cpu_axi_araddr), .slv0_arlen(cpu_axi_arlen), .slv0_arsize(cpu_axi_arsize),
    .slv0_arburst(cpu_axi_arburst), .slv0_arlock(1'b0), .slv0_arcache(4'b0),
    .slv0_arprot(cpu_axi_arprot), .slv0_arqos(4'b0), .slv0_arregion(4'b0),
    .slv0_arid(cpu_axi_arid), .slv0_aruser(1'b0),
    .slv0_rvalid(cpu_axi_rvalid), .slv0_rready(cpu_axi_rready),
    .slv0_rid(cpu_axi_rid), .slv0_rresp(cpu_axi_rresp), .slv0_rdata(cpu_axi_rdata),
    .slv0_rlast(cpu_axi_rlast), .slv0_ruser(),

    // Slave 1: DMA master
    .slv1_aclk(clk), .slv1_aresetn(resetn), .slv1_srst(rst),
    .slv1_awvalid(dma_axi_awvalid), .slv1_awready(dma_axi_awready),
    .slv1_awaddr(dma_axi_awaddr), .slv1_awlen(dma_axi_awlen), .slv1_awsize(dma_axi_awsize),
    .slv1_awburst(dma_axi_awburst), .slv1_awlock(dma_axi_awlock), .slv1_awcache(4'b0),
    .slv1_awprot(dma_axi_awprot), .slv1_awqos(4'b0), .slv1_awregion(4'b0),
    .slv1_awid(dma_axi_awid), .slv1_awuser(1'b0),
    .slv1_wvalid(dma_axi_wvalid), .slv1_wready(dma_axi_wready),
    .slv1_wlast(dma_axi_wlast), .slv1_wdata(dma_axi_wdata), .slv1_wstrb(dma_axi_wstrb),
    .slv1_wuser(1'b0),
    .slv1_bvalid(dma_axi_bvalid), .slv1_bready(dma_axi_bready),
    .slv1_bid(dma_axi_bid), .slv1_bresp(dma_axi_bresp_xbar), .slv1_buser(),
    .slv1_arvalid(dma_axi_arvalid), .slv1_arready(dma_axi_arready),
    .slv1_araddr(dma_axi_araddr), .slv1_arlen(dma_axi_arlen), .slv1_arsize(dma_axi_arsize),
    .slv1_arburst(dma_axi_arburst), .slv1_arlock(dma_axi_arlock), .slv1_arcache(4'b0),
    .slv1_arprot(dma_axi_arprot), .slv1_arqos(4'b0), .slv1_arregion(4'b0),
    .slv1_arid(dma_axi_arid), .slv1_aruser(1'b0),
    .slv1_rvalid(dma_axi_rvalid), .slv1_rready(dma_axi_rready),
    .slv1_rid(dma_axi_rid), .slv1_rresp(dma_axi_rresp_xbar), .slv1_rdata(dma_axi_rdata),
    .slv1_rlast(dma_axi_rlast), .slv1_ruser(),

    // Slave 2/3 未连接
    .slv2_aclk(clk), .slv2_aresetn(resetn), .slv2_srst(rst),
    .slv2_awvalid(1'b0), .slv2_awaddr('0), .slv2_awlen('0), .slv2_awsize('0),
    .slv2_awburst('0), .slv2_awlock(1'b0), .slv2_awcache(4'b0), .slv2_awprot(3'b0),
    .slv2_awqos(4'b0), .slv2_awregion(4'b0), .slv2_awid('0), .slv2_awuser(1'b0),
    .slv2_wvalid(1'b0), .slv2_wlast(1'b0), .slv2_wdata('0), .slv2_wstrb('0), .slv2_wuser(1'b0),
    .slv2_bready(1'b0),
    .slv2_arvalid(1'b0), .slv2_araddr('0), .slv2_arlen('0), .slv2_arsize('0),
    .slv2_arburst('0), .slv2_arlock(1'b0), .slv2_arcache(4'b0), .slv2_arprot(3'b0),
    .slv2_arqos(4'b0), .slv2_arregion(4'b0), .slv2_arid('0), .slv2_aruser(1'b0),
    .slv2_rready(1'b0),
    .slv2_awready(), .slv2_wready(), .slv2_bvalid(), .slv2_bid(), .slv2_bresp(),
    .slv2_buser(), .slv2_arready(), .slv2_rvalid(), .slv2_rid(), .slv2_rresp(),
    .slv2_rdata(), .slv2_rlast(), .slv2_ruser(),

    .slv3_aclk(clk), .slv3_aresetn(resetn), .slv3_srst(rst),
    .slv3_awvalid(1'b0), .slv3_awaddr('0), .slv3_awlen('0), .slv3_awsize('0),
    .slv3_awburst('0), .slv3_awlock(1'b0), .slv3_awcache(4'b0), .slv3_awprot(3'b0),
    .slv3_awqos(4'b0), .slv3_awregion(4'b0), .slv3_awid('0), .slv3_awuser(1'b0),
    .slv3_wvalid(1'b0), .slv3_wlast(1'b0), .slv3_wdata('0), .slv3_wstrb('0), .slv3_wuser(1'b0),
    .slv3_bready(1'b0),
    .slv3_arvalid(1'b0), .slv3_araddr('0), .slv3_arlen('0), .slv3_arsize('0),
    .slv3_arburst('0), .slv3_arlock(1'b0), .slv3_arcache(4'b0), .slv3_arprot(3'b0),
    .slv3_arqos(4'b0), .slv3_arregion(4'b0), .slv3_arid('0), .slv3_aruser(1'b0),
    .slv3_rready(1'b0),
    .slv3_awready(), .slv3_wready(), .slv3_bvalid(), .slv3_bid(), .slv3_bresp(),
    .slv3_buser(), .slv3_arready(), .slv3_rvalid(), .slv3_rid(), .slv3_rresp(),
    .slv3_rdata(), .slv3_rlast(), .slv3_ruser(),

    // Master 0: DDR
    .mst0_aclk(clk), .mst0_aresetn(resetn), .mst0_srst(rst),
    .mst0_awvalid(xbar_mst0_awvalid), .mst0_awready(xbar_mst0_awready),
    .mst0_awaddr(xbar_mst0_awaddr), .mst0_awlen(xbar_mst0_awlen), .mst0_awsize(xbar_mst0_awsize),
    .mst0_awburst(xbar_mst0_awburst), .mst0_awlock(xbar_mst0_awlock),
    .mst0_awcache(xbar_mst0_awcache), .mst0_awprot(xbar_mst0_awprot),
    .mst0_awqos(xbar_mst0_awqos), .mst0_awregion(xbar_mst0_awregion),
    .mst0_awid(xbar_mst0_awid), .mst0_awuser(),
    .mst0_wvalid(xbar_mst0_wvalid), .mst0_wready(xbar_mst0_wready),
    .mst0_wlast(xbar_mst0_wlast), .mst0_wdata(xbar_mst0_wdata), .mst0_wstrb(xbar_mst0_wstrb),
    .mst0_wuser(),
    .mst0_bvalid(xbar_mst0_bvalid), .mst0_bready(xbar_mst0_bready),
    .mst0_bid(xbar_mst0_bid), .mst0_bresp(xbar_mst0_bresp), .mst0_buser(1'b0),
    .mst0_arvalid(xbar_mst0_arvalid), .mst0_arready(xbar_mst0_arready),
    .mst0_araddr(xbar_mst0_araddr), .mst0_arlen(xbar_mst0_arlen), .mst0_arsize(xbar_mst0_arsize),
    .mst0_arburst(xbar_mst0_arburst), .mst0_arlock(xbar_mst0_arlock),
    .mst0_arcache(xbar_mst0_arcache), .mst0_arprot(xbar_mst0_arprot),
    .mst0_arqos(xbar_mst0_arqos), .mst0_arregion(xbar_mst0_arregion),
    .mst0_arid(xbar_mst0_arid), .mst0_aruser(),
    .mst0_rvalid(xbar_mst0_rvalid), .mst0_rready(xbar_mst0_rready),
    .mst0_rid(xbar_mst0_rid), .mst0_rresp(xbar_mst0_rresp), .mst0_rdata(xbar_mst0_rdata),
    .mst0_rlast(xbar_mst0_rlast), .mst0_ruser(1'b0),

    // Master 1: NPU LMEM
    .mst1_aclk(clk), .mst1_aresetn(resetn), .mst1_srst(rst),
    .mst1_awvalid(xbar_mst1_awvalid), .mst1_awready(xbar_mst1_awready),
    .mst1_awaddr(xbar_mst1_awaddr), .mst1_awlen(xbar_mst1_awlen), .mst1_awsize(xbar_mst1_awsize),
    .mst1_awburst(xbar_mst1_awburst), .mst1_awlock(xbar_mst1_awlock),
    .mst1_awcache(xbar_mst1_awcache), .mst1_awprot(xbar_mst1_awprot),
    .mst1_awqos(xbar_mst1_awqos), .mst1_awregion(xbar_mst1_awregion),
    .mst1_awid(xbar_mst1_awid), .mst1_awuser(),
    .mst1_wvalid(xbar_mst1_wvalid), .mst1_wready(xbar_mst1_wready),
    .mst1_wlast(xbar_mst1_wlast), .mst1_wdata(xbar_mst1_wdata), .mst1_wstrb(xbar_mst1_wstrb),
    .mst1_wuser(),
    .mst1_bvalid(xbar_mst1_bvalid), .mst1_bready(xbar_mst1_bready),
    .mst1_bid(xbar_mst1_bid), .mst1_bresp(xbar_mst1_bresp), .mst1_buser(1'b0),
    .mst1_arvalid(xbar_mst1_arvalid), .mst1_arready(xbar_mst1_arready),
    .mst1_araddr(xbar_mst1_araddr), .mst1_arlen(xbar_mst1_arlen), .mst1_arsize(xbar_mst1_arsize),
    .mst1_arburst(xbar_mst1_arburst), .mst1_arlock(xbar_mst1_arlock),
    .mst1_arcache(xbar_mst1_arcache), .mst1_arprot(xbar_mst1_arprot),
    .mst1_arqos(xbar_mst1_arqos), .mst1_arregion(xbar_mst1_arregion),
    .mst1_arid(xbar_mst1_arid), .mst1_aruser(),
    .mst1_rvalid(xbar_mst1_rvalid), .mst1_rready(xbar_mst1_rready),
    .mst1_rid(xbar_mst1_rid), .mst1_rresp(xbar_mst1_rresp), .mst1_rdata(xbar_mst1_rdata),
    .mst1_rlast(xbar_mst1_rlast), .mst1_ruser(1'b0),

    // Master 2: DMA CSR (经过桥)
    .mst2_aclk(clk), .mst2_aresetn(resetn), .mst2_srst(rst),
    .mst2_awvalid(xbar_mst2_awvalid), .mst2_awready(xbar_mst2_awready),
    .mst2_awaddr(xbar_mst2_awaddr), .mst2_awlen(xbar_mst2_awlen), .mst2_awsize(xbar_mst2_awsize),
    .mst2_awburst(xbar_mst2_awburst), .mst2_awlock(xbar_mst2_awlock),
    .mst2_awcache(xbar_mst2_awcache), .mst2_awprot(xbar_mst2_awprot),
    .mst2_awqos(xbar_mst2_awqos), .mst2_awregion(xbar_mst2_awregion),
    .mst2_awid(xbar_mst2_awid), .mst2_awuser(),
    .mst2_wvalid(xbar_mst2_wvalid), .mst2_wready(xbar_mst2_wready),
    .mst2_wlast(xbar_mst2_wlast), .mst2_wdata(xbar_mst2_wdata), .mst2_wstrb(xbar_mst2_wstrb),
    .mst2_wuser(),
    .mst2_bvalid(xbar_mst2_bvalid), .mst2_bready(xbar_mst2_bready),
    .mst2_bid(xbar_mst2_bid), .mst2_bresp(xbar_mst2_bresp), .mst2_buser(1'b0),
    .mst2_arvalid(xbar_mst2_arvalid), .mst2_arready(xbar_mst2_arready),
    .mst2_araddr(xbar_mst2_araddr), .mst2_arlen(xbar_mst2_arlen), .mst2_arsize(xbar_mst2_arsize),
    .mst2_arburst(xbar_mst2_arburst), .mst2_arlock(xbar_mst2_arlock),
    .mst2_arcache(xbar_mst2_arcache), .mst2_arprot(xbar_mst2_arprot),
    .mst2_arqos(xbar_mst2_arqos), .mst2_arregion(xbar_mst2_arregion),
    .mst2_arid(xbar_mst2_arid), .mst2_aruser(),
    .mst2_rvalid(xbar_mst2_rvalid), .mst2_rready(xbar_mst2_rready),
    .mst2_rid(xbar_mst2_rid), .mst2_rresp(xbar_mst2_rresp), .mst2_rdata(xbar_mst2_rdata),
    .mst2_rlast(xbar_mst2_rlast), .mst2_ruser(1'b0),

    // Master 3: NPU Registers
    .mst3_aclk(clk), .mst3_aresetn(resetn), .mst3_srst(rst),
    .mst3_awvalid(xbar_mst3_awvalid), .mst3_awready(xbar_mst3_awready),
    .mst3_awaddr(xbar_mst3_awaddr), .mst3_awlen(xbar_mst3_awlen), .mst3_awsize(xbar_mst3_awsize),
    .mst3_awburst(xbar_mst3_awburst), .mst3_awlock(xbar_mst3_awlock),
    .mst3_awcache(xbar_mst3_awcache), .mst3_awprot(xbar_mst3_awprot),
    .mst3_awqos(xbar_mst3_awqos), .mst3_awregion(xbar_mst3_awregion),
    .mst3_awid(xbar_mst3_awid), .mst3_awuser(),
    .mst3_wvalid(xbar_mst3_wvalid), .mst3_wready(xbar_mst3_wready),
    .mst3_wlast(xbar_mst3_wlast), .mst3_wdata(xbar_mst3_wdata), .mst3_wstrb(xbar_mst3_wstrb),
    .mst3_wuser(),
    .mst3_bvalid(xbar_mst3_bvalid), .mst3_bready(xbar_mst3_bready),
    .mst3_bid(xbar_mst3_bid), .mst3_bresp(xbar_mst3_bresp), .mst3_buser(1'b0),
    .mst3_arvalid(xbar_mst3_arvalid), .mst3_arready(xbar_mst3_arready),
    .mst3_araddr(xbar_mst3_araddr), .mst3_arlen(xbar_mst3_arlen), .mst3_arsize(xbar_mst3_arsize),
    .mst3_arburst(xbar_mst3_arburst), .mst3_arlock(xbar_mst3_arlock),
    .mst3_arcache(xbar_mst3_arcache), .mst3_arprot(xbar_mst3_arprot),
    .mst3_arqos(xbar_mst3_arqos), .mst3_arregion(xbar_mst3_arregion),
    .mst3_arid(xbar_mst3_arid), .mst3_aruser(),
    .mst3_rvalid(xbar_mst3_rvalid), .mst3_rready(xbar_mst3_rready),
    .mst3_rid(xbar_mst3_rid), .mst3_rresp(xbar_mst3_rresp), .mst3_rdata(xbar_mst3_rdata),
    .mst3_rlast(xbar_mst3_rlast), .mst3_ruser(1'b0)
  );

  // ==========================================================
  // 从设备实例
  // ==========================================================
  // DDR (从设备 0)
  ddr #(
    .AXI_ID_W(AXI_ID_W), .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
    .DDR_SIZE_BYTES(DDR_SIZE_BYTES), .DDR_INIT_FILE(DDR_INIT_FILE)
  ) u_ddr (
    .aclk(clk), .aresetn(resetn),
    .s_awvalid(xbar_mst0_awvalid), .s_awready(xbar_mst0_awready),
    .s_awaddr(xbar_mst0_awaddr), .s_awlen(xbar_mst0_awlen), .s_awsize(xbar_mst0_awsize),
    .s_awburst(xbar_mst0_awburst), .s_awid(xbar_mst0_awid),
    .s_wvalid(xbar_mst0_wvalid), .s_wready(xbar_mst0_wready),
    .s_wdata(xbar_mst0_wdata), .s_wstrb(xbar_mst0_wstrb), .s_wlast(xbar_mst0_wlast),
    .s_bvalid(xbar_mst0_bvalid), .s_bready(xbar_mst0_bready),
    .s_bresp(xbar_mst0_bresp), .s_bid(xbar_mst0_bid),
    .s_arvalid(xbar_mst0_arvalid), .s_arready(xbar_mst0_arready),
    .s_araddr(xbar_mst0_araddr), .s_arlen(xbar_mst0_arlen), .s_arsize(xbar_mst0_arsize),
    .s_arburst(xbar_mst0_arburst), .s_arid(xbar_mst0_arid),
    .s_rvalid(xbar_mst0_rvalid), .s_rready(xbar_mst0_rready),
    .s_rdata(xbar_mst0_rdata), .s_rresp(xbar_mst0_rresp), .s_rlast(xbar_mst0_rlast),
    .s_rid(xbar_mst0_rid)
  );

  // NPU 本地存储器 (从设备 1)
  npu_ram #(
    .AXI_ID_W(AXI_ID_W), .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
    .MEM_BYTES(NPU_LMEM_SIZE_BYTES), .READ_LATENCY(1)
  ) u_npu_ram (
    .aclk(clk), .aresetn(resetn),
    .s_awvalid(xbar_mst1_awvalid), .s_awready(xbar_mst1_awready),
    .s_awaddr(xbar_mst1_awaddr), .s_awlen(xbar_mst1_awlen), .s_awsize(xbar_mst1_awsize),
    .s_awburst(xbar_mst1_awburst), .s_awid(xbar_mst1_awid),
    .s_wvalid(xbar_mst1_wvalid), .s_wready(xbar_mst1_wready),
    .s_wdata(xbar_mst1_wdata), .s_wstrb(xbar_mst1_wstrb), .s_wlast(xbar_mst1_wlast),
    .s_bvalid(xbar_mst1_bvalid), .s_bready(xbar_mst1_bready),
    .s_bresp(xbar_mst1_bresp), .s_bid(xbar_mst1_bid),
    .s_arvalid(xbar_mst1_arvalid), .s_arready(xbar_mst1_arready),
    .s_araddr(xbar_mst1_araddr), .s_arlen(xbar_mst1_arlen), .s_arsize(xbar_mst1_arsize),
    .s_arburst(xbar_mst1_arburst), .s_arid(xbar_mst1_arid),
    .s_rvalid(xbar_mst1_rvalid), .s_rready(xbar_mst1_rready),
    .s_rdata(xbar_mst1_rdata), .s_rresp(xbar_mst1_rresp), .s_rlast(xbar_mst1_rlast),
    .s_rid(xbar_mst1_rid)
  );

  // NPU 控制寄存器 (从设备 3)
  npu_csr #(
    .AXI_ID_W(AXI_ID_W), .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
    .BASE_ADDR(NPU_CSR_BASE), .IS_DMA(0)
  ) u_csr_npu (
    .aclk(clk), .aresetn(resetn),
    .s_awvalid(xbar_mst3_awvalid), .s_awready(xbar_mst3_awready),
    .s_awaddr(xbar_mst3_awaddr), .s_awlen(xbar_mst3_awlen), .s_awsize(xbar_mst3_awsize),
    .s_awburst(xbar_mst3_awburst), .s_awid(xbar_mst3_awid),
    .s_wvalid(xbar_mst3_wvalid), .s_wready(xbar_mst3_wready),
    .s_wdata(xbar_mst3_wdata), .s_wstrb(xbar_mst3_wstrb), .s_wlast(xbar_mst3_wlast),
    .s_bvalid(xbar_mst3_bvalid), .s_bready(xbar_mst3_bready),
    .s_bresp(xbar_mst3_bresp), .s_bid(xbar_mst3_bid),
    .s_arvalid(xbar_mst3_arvalid), .s_arready(xbar_mst3_arready),
    .s_araddr(xbar_mst3_araddr), .s_arlen(xbar_mst3_arlen), .s_arsize(xbar_mst3_arsize),
    .s_arburst(xbar_mst3_arburst), .s_arid(xbar_mst3_arid),
    .s_rvalid(xbar_mst3_rvalid), .s_rready(xbar_mst3_rready),
    .s_rdata(xbar_mst3_rdata), .s_rresp(xbar_mst3_rresp), .s_rlast(xbar_mst3_rlast),
    .s_rid(xbar_mst3_rid)
  );

// DMA 控制寄存器 
  initial begin
  @(negedge rst);
  repeat(1000) @(posedge clk);
  $display("[TB] DMA CSR: go=%0d abort=%0d max_burst=0x%x",
           u_dma.u_dma_axi_wrapper.u_dma_csr.reg_go, u_dma.u_dma_axi_wrapper.u_dma_csr.reg_abort, u_dma.u_dma_axi_wrapper.u_dma_csr.reg_max_burst);
  $display("[TB] SRC0=0x%08x DST0=0x%08x NUM0=0x%08x CFG0=0x%x",
           u_dma.u_dma_axi_wrapper.u_dma_csr.reg_src_addr[0], u_dma.u_dma_axi_wrapper.u_dma_csr.reg_dst_addr[0],
           u_dma.u_dma_axi_wrapper.u_dma_csr.reg_num_bytes[0], u_dma.u_dma_axi_wrapper.u_dma_csr.reg_enable[0]);
end
/*
initial begin
  forever begin
    #10000; // 每 10 us 打印一次
    if (!rst && !dma_done && !dma_error && !cpu_trap) begin
      $display("[TB] Status at %t: dma_done=%0d, dma_error=%0d, cpu_trap=%0d", $time, dma_done, dma_error, cpu_trap);
      $display("[TB] u_dma.u_dma_axi_if.wr_counter_ff=%0d, rd_counter_ff=%0d, aw_txn_started_ff=%0d",
               u_dma.u_dma_axi_wrapper.u_dma_func_wrapper.u_dma_axi_if.wr_counter_ff, u_dma.u_dma_axi_wrapper.u_dma_func_wrapper.u_dma_axi_if.rd_counter_ff, u_dma.u_dma_axi_wrapper.u_dma_func_wrapper.u_dma_axi_if.aw_txn_started_ff);
      $display("[TB] dma_axi_rd_req_i.valid=%0d, dma_axi_wr_req_i.valid=%0d",
               u_dma.u_dma_axi_wrapper.u_dma_func_wrapper.u_dma_axi_if.dma_axi_rd_req_i.valid, u_dma.u_dma_axi_wrapper.u_dma_func_wrapper.u_dma_axi_if.dma_axi_wr_req_i.valid);
    end
  end
end*/
/*
// ==========================
// DMA AXI 观测计数器（最小集）
// ==========================
int c_dma_aw, c_dma_w, c_dma_b, c_dma_ar, c_dma_r;
int c_dma_wlast, c_dma_rlast;

always_ff @(posedge clk) begin
  if (rst) begin
    c_dma_aw   <= 0;
    c_dma_w    <= 0;
    c_dma_b    <= 0;
    c_dma_ar   <= 0;
    c_dma_r    <= 0;
    c_dma_wlast<= 0;
    c_dma_rlast<= 0;
  end else begin
    if (dma_axi_awvalid && dma_axi_awready) begin
      c_dma_aw <= c_dma_aw + 1;
      $display("[SOC][DMA] AW hs t=%0t addr=%08x len=%0d", $time, dma_axi_awaddr, dma_axi_awlen);
    end
    if (dma_axi_wvalid && dma_axi_wready) begin
      c_dma_w <= c_dma_w + 1;
      if (dma_axi_wlast) begin
        c_dma_wlast <= c_dma_wlast + 1;
        $display("[SOC][DMA] WLAST hs t=%0t", $time);
      end
    end
    if (dma_axi_bvalid && dma_axi_bready) begin
      c_dma_b <= c_dma_b + 1;
      $display("[SOC][DMA] B hs t=%0t resp=%0d", $time, dma_axi_bresp);
    end

    if (dma_axi_arvalid && dma_axi_arready) begin
      c_dma_ar <= c_dma_ar + 1;
      $display("[SOC][DMA] AR hs t=%0t addr=%08x len=%0d", $time, dma_axi_araddr, dma_axi_arlen);
    end
    if (dma_axi_rvalid && dma_axi_rready) begin
      c_dma_r <= c_dma_r + 1;
      if (dma_axi_rlast) begin
        c_dma_rlast <= c_dma_rlast + 1;
        $display("[SOC][DMA] RLAST hs t=%0t", $time);
      end
    end
  end
end
*/
  initial begin : DMA_TIMEOUT_GUARD
  wait(!rst);
  #2ms;
  if (!(dma_done || dma_error || cpu_trap)) begin
    $error("[TB] TIMEOUT: no dma_done/dma_error/cpu_trap within 2ms");
    $stop;
  end
end

// 模块级别定义打印函数，增加 base_src 和 base_dst 参数
function void print_block(string name, string location, int start_off, int end_off, int base_src, int base_dst);
    int j;
    $display("[TB] %s %s @0x%08x (bytes %0d - %0d):", name, location,
             (location == "SRC") ? 32'h4000_0000 : 32'h0000_1000,
             start_off, end_off);
    for (j = start_off; j <= end_off; j = j + 1) begin
        if ((j - start_off) % 16 == 0) $write("  +0x%03x : ", j);
        if (location == "SRC")
            $write("%02x ", u_ddr.mem[base_src + j]);
        else
            $write("%02x ", u_npu_ram.mem[base_dst + j]);
        if ((j - start_off) % 16 == 15) $write("\n");
    end
    if ((end_off - start_off + 1) % 16 != 0) $write("\n");
endfunction

initial begin : DMA_END2END_CHECK
    // 变量声明
    int i;
    int src_base_ddr;
    int dst_base_lmem;
    int check_bytes;
    bit mismatch;
    int start0, end0;
    int start1, end1;
    int start2, end2;

    localparam int DMA_BYTES = 4088;

    // 地址计算
    src_base_ddr  = 32'h4000_0000 - DDR_BASE;
    dst_base_lmem = 32'h0000_1000 - NPU_LMEM_BASE;
    check_bytes = (DMA_BYTES < NPU_LMEM_SIZE_BYTES) ? DMA_BYTES : NPU_LMEM_SIZE_BYTES;

    // 计算前、中、后各 64 字节的范围
    start0 = 0;
    end0   = (check_bytes >= 64) ? 63 : check_bytes - 1;

    start1 = (check_bytes / 2) - 32;
    if (start1 < 0) start1 = 0;
    end1   = start1 + 63;
    if (end1 >= check_bytes) begin
        end1 = check_bytes - 1;
        start1 = (end1 >= 63) ? end1 - 63 : 0;
    end

    start2 = (check_bytes >= 64) ? check_bytes - 64 : 0;
    end2   = check_bytes - 1;

    // 预加载数据
    @(negedge rst);
    @(posedge clk);
    for (i = 0; i < check_bytes; i = i + 1) begin
        u_ddr.mem[src_base_ddr + i]  = (8'h10 + i[7:0]);
        u_npu_ram.mem[dst_base_lmem + i] = 8'h00;
    end

    $display("\n[TB] ===== PRELOAD DONE (bytes=%0d) =====", check_bytes);
    for (i = 0; i < 16; i = i + 1)
        $display("[TB] preload SRC[%0d]=%02x DST[%0d]=%02x",
                 i, u_ddr.mem[src_base_ddr + i], i, u_npu_ram.mem[dst_base_lmem + i]);

    repeat (10) @(posedge clk);

    // DMA 前打印
    $display("\n[TB] ===== BEFORE DMA COPY =====");
    print_block("DDR", "SRC", start0, end0, src_base_ddr, dst_base_lmem);
    if (start1 != start0 || end1 != end0) 
        print_block("DDR", "SRC", start1, end1, src_base_ddr, dst_base_lmem);
    if (start2 != start1 || end2 != end1) 
        print_block("DDR", "SRC", start2, end2, src_base_ddr, dst_base_lmem);
    // 等待 DMA 结束
    fork
        begin
            wait(dma_done || dma_error || cpu_trap);
        end
        begin
            #2ms;
            $error("[TB] TIMEOUT: no dma_done/dma_error/cpu_trap within 2ms");
            $stop;
        end
    join_any
    disable fork;
    #1;

    // DMA 后打印
    $display("\n[TB] ===== AFTER DMA COPY =====");
    $display("[TB] status: trap=%0b done=%0b err=%0b", cpu_trap, dma_done, dma_error);
    print_block("DDR", "SRC", start0, end0, src_base_ddr, dst_base_lmem);
    if (start1 != start0 || end1 != end0) print_block("DDR", "SRC", start1, end1, src_base_ddr, dst_base_lmem );
    if (start2 != start1 || end2 != end1) print_block("DDR", "SRC", start2, end2, src_base_ddr, dst_base_lmem);

    print_block("NPU_LMEM", "DST", start0, end0, src_base_ddr, dst_base_lmem);
    if (start1 != start0 || end1 != end0) print_block("NPU_LMEM", "DST", start1, end1, src_base_ddr, dst_base_lmem);
    if (start2 != start1 || end2 != end1) print_block("NPU_LMEM", "DST", start2, end2, src_base_ddr, dst_base_lmem );

    // 全量校验
    mismatch = 0;
    for (i = 0; i < check_bytes; i = i + 1) begin
        if (u_ddr.mem[src_base_ddr + i] !== u_npu_ram.mem[dst_base_lmem + i]) begin
            mismatch = 1;
            $display("[TB] MISMATCH byte[%0d] SRC=%02x DST=%02x",
                     i, u_ddr.mem[src_base_ddr + i], u_npu_ram.mem[dst_base_lmem + i]);
        end
    end

    if (cpu_trap)        $error("[TB] FAIL: cpu_trap");
    else if (dma_error)  $error("[TB] FAIL: dma_error asserted");
    else if (!dma_done)  $error("[TB] FAIL: dma_done not asserted");
    else if (mismatch)   $error("[TB] FAIL: DDR->LMEM data mismatch");
    else                 $display("[TB] PASS: DMA copied %0d bytes DDR->NPU_LMEM.", check_bytes);
    $stop;
end
endmodule
`default_nettype wire