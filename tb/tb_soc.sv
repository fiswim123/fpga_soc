`timescale 1ns/1ps
`default_nettype none

`include "../src/dma/inc/amba_axi.svh"
`include "../src/dma/inc/dma_pkg.svh"

module tb_soc;
  import amba_axi_pkg::*;
  import dma_utils_pkg::*;

  // ==========================================================
  // 参数定义
  // ==========================================================
  localparam int AXI_ADDR_W = 32;
  localparam int AXI_DATA_W = 160;
  localparam int AXI_ID_W   = 8;
  localparam int NPU_AXI_DATA_W = 160;

  parameter [8*128-1:0] LOCAL_ROM_INIT_FILE = "";
  parameter [8*128-1:0] DDR_INIT_FILE = "";

  // CPU 本地存储器
  localparam logic [31:0] CPU_ROM_BASE = 32'h0000_0000;
  localparam int          CPU_ROM_AW   = 12;
  localparam logic [31:0] CPU_RAM_BASE = 32'h1000_0000;
  localparam int          CPU_RAM_AW   = 12;
  
  // 系统总线地址映射
  localparam logic [31:0] NPU_RAM_BASE = 32'h0000_1000;
  localparam int          NPU_RAM_SIZE_BYTES = 20480;
  localparam logic [31:0] NPU_RAM_MASK = 32'hFFFF_0000;
  
  localparam logic [31:0] NPU_CSR_BASE = 32'h0002_0000;
  localparam int          NPU_CSR_SIZE_BYTES = 4096;
  localparam logic [31:0] NPU_CSR_MASK = 32'hFFFF_F000;
  
  localparam logic [31:0] DMA_CSR_BASE = 32'h0002_1000;
  localparam int          DMA_CSR_SIZE_BYTES = 4096;
  localparam logic [31:0] DMA_CSR_MASK = 32'hFFFF_F000;

  localparam logic [31:0] DMA_ROM_BASE  = 32'h8000_0000;
  localparam int          DMA_BYTES     = 14400;
  localparam int          DMA_WORD_OFFSET = (32'h1400) / (AXI_DATA_W/8);
  localparam logic [31:0] NPU_DST_ADDR  = 32'h0000_1400;

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
  // CPU 模块接口
  // ==========================================================

  // PicoRV32 的 AXI4-Lite 接口信号
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
  logic pcpi_wr, pcpi_wait, pcpi_ready;
  logic [31:0] pcpi_rd, irq, eoi;
  logic trace_valid, pcpi_valid;
  logic [35:0] trace_data;
  logic [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2;
  assign pcpi_wr=0; assign pcpi_rd=0; assign pcpi_wait=0; assign pcpi_ready=0; assign irq=0;

  // CPU 经过桥接后的 AXI4 接口，作为crossbar的主设备0）
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

  // DMA 模块 AXI4-Lite CSR 接口信号
  logic        dma_csr_lite_awvalid;
  logic        dma_csr_lite_awready;
  logic [31:0] dma_csr_lite_awaddr;
  logic        dma_csr_lite_wvalid;
  logic        dma_csr_lite_wready;
  logic [31:0] dma_csr_lite_wdata;
  logic [3:0]  dma_csr_lite_wstrb;
  logic        dma_csr_lite_bvalid;
  logic        dma_csr_lite_bready;
  logic [1:0]  dma_csr_lite_bresp;
  logic        dma_csr_lite_arvalid;
  logic        dma_csr_lite_arready;
  logic [31:0] dma_csr_lite_araddr;
  logic        dma_csr_lite_rvalid;
  logic        dma_csr_lite_rready;
  logic [31:0] dma_csr_lite_rdata;
  logic [1:0]  dma_csr_lite_rresp;
  axi_prot_t   dma_csr_lite_awprot;
  axi_prot_t   dma_csr_lite_arprot;
  wire [1:0] dma_csr_lite_awprot_bridge;  // 用于连接桥的对应端口
  wire [1:0] dma_csr_lite_arprot_bridge;  // 用于连接桥的对应端口

  // DMA 模块 AXI4 CSR 接口信号,作为 crossbar 的从设备2, 连接至 AXI4 to AXI4-Lite 桥的 AXI4 端
  logic                  dma_csr_axi_awvalid, dma_csr_axi_awready;
  logic [AXI_ADDR_W-1:0] dma_csr_axi_awaddr;
  logic [7:0]            dma_csr_axi_awlen;
  logic [2:0]            dma_csr_axi_awsize;
  logic [1:0]            dma_csr_axi_awburst;
  logic                  dma_csr_axi_awlock;
  logic [3:0]            dma_csr_axi_awcache;
  logic [2:0]            dma_csr_axi_awprot;
  logic [3:0]            dma_csr_axi_awqos;
  logic [3:0]            dma_csr_axi_awregion;
  logic [AXI_ID_W-1:0]   dma_csr_axi_awid;
  logic                  dma_csr_axi_wvalid, dma_csr_axi_wready;
  logic [AXI_ID_W-1:0]   dma_csr_axi_wid;
  logic [AXI_DATA_W-1:0] dma_csr_axi_wdata;
  logic [AXI_DATA_W/8-1:0] dma_csr_axi_wstrb;
  logic                  dma_csr_axi_wlast;
  logic                  dma_csr_axi_bvalid, dma_csr_axi_bready;
  logic [AXI_ID_W-1:0]   dma_csr_axi_bid;
  logic [1:0]            dma_csr_axi_bresp;
  logic                  dma_csr_axi_arvalid, dma_csr_axi_arready;
  logic [AXI_ADDR_W-1:0] dma_csr_axi_araddr;
  logic [7:0]            dma_csr_axi_arlen;
  logic [2:0]            dma_csr_axi_arsize;
  logic [1:0]            dma_csr_axi_arburst;
  logic                  dma_csr_axi_arlock;
  logic [3:0]            dma_csr_axi_arcache;
  logic [2:0]            dma_csr_axi_arprot;
  logic [3:0]            dma_csr_axi_arqos;
  logic [3:0]            dma_csr_axi_arregion;
  logic [AXI_ID_W-1:0]   dma_csr_axi_arid;
  logic                  dma_csr_axi_rvalid, dma_csr_axi_rready;
  logic [AXI_ID_W-1:0]   dma_csr_axi_rid;
  logic [1:0]            dma_csr_axi_rresp;
  logic [AXI_DATA_W-1:0] dma_csr_axi_rdata;
  logic                  dma_csr_axi_rlast;

  // DMA 模块 AXI4 主接口信号，作为crossbar的主设备1
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
  logic [AXI_DATA_W-1:0] dma_axi_wdata;
  logic [AXI_DATA_W/8-1:0]dma_axi_wstrb;
  logic                  dma_axi_wlast;
  logic                  dma_axi_wuser;
  logic                  dma_axi_wvalid;
  logic                  dma_axi_wready;
  logic [AXI_ID_W-1:0]   dma_axi_bid;
  logic                  dma_axi_buser;
  logic                  dma_axi_bvalid;
  logic                  dma_axi_bready;
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
  logic [AXI_ID_W-1:0]   dma_axi_rid;
  logic [AXI_DATA_W-1:0] dma_axi_rdata;
  logic                  dma_axi_rlast;
  logic                  dma_axi_ruser;
  logic                  dma_axi_rvalid;
  logic                  dma_axi_rready;
  // ===== 使用包类型 =====
  axi_resp_t             dma_axi_bresp;
  axi_resp_t             dma_axi_rresp;

  //
  wire [1:0] dma_axi_bresp_xbar;
  wire [1:0] dma_axi_rresp_xbar;
  // 注意：dma_axi_bresp 和 dma_axi_rresp 是 axi_resp_t 类型，需要转换为 2-bit 的 AXI 响应信号连接到 crossbar
  assign dma_axi_bresp_xbar = dma_axi_bresp;  // 隐式枚举到 logic[1:0]
  assign dma_axi_rresp_xbar = dma_axi_rresp;


  logic dma_done, dma_error;

  // ==========================================================
  // NPU 模块接口
  // ==========================================================

  // NPU 模块 AXI4-Lite CSR 接口信号
  wire                       npu_csr_lite_awvalid;
  wire                       npu_csr_lite_awready;
  wire [31:0]                npu_csr_lite_awaddr;
  wire [1:0]                 npu_csr_lite_awprot;
  wire                       npu_csr_lite_wvalid;
  wire                       npu_csr_lite_wready;
  wire [31:0]                npu_csr_lite_wdata;
  wire [3:0]                 npu_csr_lite_wstrb;
  wire                       npu_csr_lite_bvalid;
  wire                       npu_csr_lite_bready;
  wire [1:0]                 npu_csr_lite_bresp;
  wire                       npu_csr_lite_arvalid;
  wire                       npu_csr_lite_arready;
  wire [31:0]                npu_csr_lite_araddr;
  wire [1:0]                 npu_csr_lite_arprot;
  wire                       npu_csr_lite_rvalid;
  wire                       npu_csr_lite_rready;
  wire [31:0]                npu_csr_lite_rdata;
  wire [1:0]                 npu_csr_lite_rresp;

  // NPU 模块 AXI4 主接口信号，作为 crossbar 的主设备1, 连接至 AXI4 to AXI4-Lite 桥的 AXI4 端
  logic                  npu_csr_axi_awvalid, npu_csr_axi_awready;
  logic [AXI_ADDR_W-1:0] npu_csr_axi_awaddr;
  logic [7:0]            npu_csr_axi_awlen;
  logic [2:0]            npu_csr_axi_awsize;
  logic [1:0]            npu_csr_axi_awburst;
  logic                  npu_csr_axi_awlock;
  logic [3:0]            npu_csr_axi_awcache;
  logic [2:0]            npu_csr_axi_awprot;
  logic [3:0]            npu_csr_axi_awqos;
  logic [3:0]            npu_csr_axi_awregion;
  logic [AXI_ID_W-1:0]   npu_csr_axi_awid;
  logic                  npu_csr_axi_wvalid, npu_csr_axi_wready;
  logic [AXI_ID_W-1:0]   npu_csr_axi_wid;
  logic [AXI_DATA_W-1:0] npu_csr_axi_wdata;
  logic [AXI_DATA_W/8-1:0] npu_csr_axi_wstrb;
  logic                  npu_csr_axi_wlast;
  logic                  npu_csr_axi_bvalid, npu_csr_axi_bready;
  logic [AXI_ID_W-1:0]   npu_csr_axi_bid;
  logic [1:0]            npu_csr_axi_bresp;
  logic                  npu_csr_axi_arvalid, npu_csr_axi_arready;
  logic [AXI_ID_W-1:0]   npu_csr_axi_arid;   // 读地址通道ID
  logic [AXI_ADDR_W-1:0] npu_csr_axi_araddr;
  logic [7:0]            npu_csr_axi_arlen;
  logic [2:0]            npu_csr_axi_arsize;
  logic [1:0]            npu_csr_axi_arburst;
  logic                  npu_csr_axi_arlock;
  logic [3:0]            npu_csr_axi_arcache;
  logic [2:0]            npu_csr_axi_arprot;
  logic [3:0]            npu_csr_axi_arqos;
  logic [3:0]            npu_csr_axi_arregion;
  logic [AXI_ID_W-1:0]   npu_csr_axi_rid;
  logic                  npu_csr_axi_rvalid, npu_csr_axi_rready;
  logic [1:0]            npu_csr_axi_rresp;
  logic [AXI_DATA_W-1:0] npu_csr_axi_rdata;
  logic                  npu_csr_axi_rlast;

  // NPU RAM AXI 从接口（连到 crossbar mst1）
  logic                       npu_ram_awvalid, npu_ram_awready;
  logic [AXI_ADDR_W-1:0]      npu_ram_awaddr;
  logic [7:0]                 npu_ram_awlen;
  logic [2:0]                 npu_ram_awsize;
  logic [1:0]                 npu_ram_awburst;
  logic                       npu_ram_awlock;
  logic [3:0]                 npu_ram_awcache;
  logic [2:0]                 npu_ram_awprot;
  logic [3:0]                 npu_ram_awqos;
  logic [3:0]                 npu_ram_awregion;
  logic [AXI_ID_W-1:0]        npu_ram_awid;
  logic                       npu_ram_wvalid, npu_ram_wready;
  logic [NPU_AXI_DATA_W-1:0]  npu_ram_wdata;
  logic [NPU_AXI_DATA_W/8-1:0]npu_ram_wstrb;
  logic                       npu_ram_wlast;
  logic                       npu_ram_bvalid, npu_ram_bready;
  logic [AXI_ID_W-1:0]        npu_ram_bid;
  logic [1:0]                 npu_ram_bresp;
  logic                       npu_ram_arvalid, npu_ram_arready;
  logic [AXI_ADDR_W-1:0]      npu_ram_araddr;
  logic [7:0]                 npu_ram_arlen;
  logic [2:0]                 npu_ram_arsize;
  logic [1:0]                 npu_ram_arburst;
  logic                       npu_ram_arlock;
  logic [3:0]                 npu_ram_arcache;
  logic [2:0]                 npu_ram_arprot;
  logic [3:0]                 npu_ram_arqos;
  logic [3:0]                 npu_ram_arregion;
  logic [AXI_ID_W-1:0]        npu_ram_arid;
  logic                       npu_ram_rvalid, npu_ram_rready;
  logic [AXI_ID_W-1:0]        npu_ram_rid;
  logic [1:0]                 npu_ram_rresp;
  logic [NPU_AXI_DATA_W-1:0]  npu_ram_rdata;
  logic                       npu_ram_rlast;
  logic                       npu_ram_ruser;
  logic                       npu_ram_buser;
  logic                       npu_ram_awuser;
  logic                       npu_ram_aruser;
  logic                       npu_ram_wuser;
  
  // NPU 结果观测
  wire                        fc2_valid;
  wire signed [10*32-1:0]     logits_out;
  wire [3:0]                  pred_class;

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

// AXI4 to AXI4-Lite 桥 (将 crossbar 的 AXI4 转为 AXI4-Lite 连接到 dma_csr)
  axi2axi_lite #(
    .DATA_WIDTH(AXI_DATA_W),
    .ADDR_WIDTH(AXI_ADDR_W),
    .ID_WIDTH(AXI_ID_W)
  ) u_dma_csr_bridge (
    .aclk(clk),
    .aresetn(resetn),
    .m_axi_lite_awaddr(dma_csr_lite_awaddr),
    .m_axi_lite_awvalid(dma_csr_lite_awvalid),
    .m_axi_lite_awready(dma_csr_lite_awready),
    .m_axi_lite_wdata(dma_csr_lite_wdata),
    .m_axi_lite_wstrb(dma_csr_lite_wstrb),
    .m_axi_lite_wvalid(dma_csr_lite_wvalid),
    .m_axi_lite_wready(dma_csr_lite_wready),
    .m_axi_lite_bresp(dma_csr_lite_bresp),
    .m_axi_lite_bvalid(dma_csr_lite_bvalid),
    .m_axi_lite_bready(dma_csr_lite_bready),
    .m_axi_lite_araddr(dma_csr_lite_araddr),
    .m_axi_lite_arvalid(dma_csr_lite_arvalid),
    .m_axi_lite_arready(dma_csr_lite_arready),
    .m_axi_lite_rdata(dma_csr_lite_rdata),
    .m_axi_lite_rresp(dma_csr_lite_rresp),
    .m_axi_lite_rvalid(dma_csr_lite_rvalid),
    .m_axi_lite_rready(dma_csr_lite_rready),
    .m_axi_lite_awprot(dma_csr_lite_awprot_bridge),
    .m_axi_lite_arprot(dma_csr_lite_arprot_bridge),

    .s_axi_awid(dma_csr_axi_awid),
    .s_axi_awaddr(dma_csr_axi_awaddr),
    .s_axi_awlen(dma_csr_axi_awlen),
    .s_axi_awsize(dma_csr_axi_awsize),
    .s_axi_awburst(dma_csr_axi_awburst),
    .s_axi_awvalid(dma_csr_axi_awvalid),
    .s_axi_awready(dma_csr_axi_awready),
    .s_axi_wid(dma_csr_axi_wid),
    .s_axi_wdata(dma_csr_axi_wdata),
    .s_axi_wstrb(dma_csr_axi_wstrb),
    .s_axi_wlast(dma_csr_axi_wlast),
    .s_axi_wvalid(dma_csr_axi_wvalid),
    .s_axi_wready(dma_csr_axi_wready),
    .s_axi_bid(dma_csr_axi_bid),
    .s_axi_bresp(dma_csr_axi_bresp),
    .s_axi_bvalid(dma_csr_axi_bvalid),
    .s_axi_bready(dma_csr_axi_bready),
    .s_axi_arid(dma_csr_axi_arid),
    .s_axi_araddr(dma_csr_axi_araddr),
    .s_axi_arlen(dma_csr_axi_arlen),
    .s_axi_arsize(dma_csr_axi_arsize),
    .s_axi_arburst(dma_csr_axi_arburst),
    .s_axi_arvalid(dma_csr_axi_arvalid),
    .s_axi_arready(dma_csr_axi_arready),
    .s_axi_rid(dma_csr_axi_rid),
    .s_axi_rdata(dma_csr_axi_rdata),
    .s_axi_rresp(dma_csr_axi_rresp),
    .s_axi_rlast(dma_csr_axi_rlast),
    .s_axi_rvalid(dma_csr_axi_rvalid),
    .s_axi_rready(dma_csr_axi_rready)
  );

// AXI4 to AXI4-Lite 桥 (将 crossbar 的 AXI4 转为 AXI4-Lite 连接到 npu_csr)
  axi2axi_lite #(
    .DATA_WIDTH(AXI_DATA_W),
    .ADDR_WIDTH(AXI_ADDR_W),
    .ID_WIDTH(AXI_ID_W)
  ) u_npu_csr_bridge (
    .aclk(clk),
    .aresetn(resetn),
    .m_axi_lite_awaddr(npu_csr_lite_awaddr),
    .m_axi_lite_awvalid(npu_csr_lite_awvalid),
    .m_axi_lite_awready(npu_csr_lite_awready),
    .m_axi_lite_wdata(npu_csr_lite_wdata),
    .m_axi_lite_wstrb(npu_csr_lite_wstrb),
    .m_axi_lite_wvalid(npu_csr_lite_wvalid),
    .m_axi_lite_wready(npu_csr_lite_wready),
    .m_axi_lite_bresp(npu_csr_lite_bresp),
    .m_axi_lite_bvalid(npu_csr_lite_bvalid),
    .m_axi_lite_bready(npu_csr_lite_bready),
    .m_axi_lite_araddr(npu_csr_lite_araddr),
    .m_axi_lite_arvalid(npu_csr_lite_arvalid),
    .m_axi_lite_arready(npu_csr_lite_arready),
    .m_axi_lite_rdata(npu_csr_lite_rdata),
    .m_axi_lite_rresp(npu_csr_lite_rresp),
    .m_axi_lite_rvalid(npu_csr_lite_rvalid),
    .m_axi_lite_rready(npu_csr_lite_rready),
    .m_axi_lite_awprot(npu_csr_lite_awprot),
    .m_axi_lite_arprot(npu_csr_lite_arprot),

    .s_axi_awid(npu_csr_axi_awid),
    .s_axi_awaddr(npu_csr_axi_awaddr),
    .s_axi_awlen(npu_csr_axi_awlen),
    .s_axi_awsize(npu_csr_axi_awsize),
    .s_axi_awburst(npu_csr_axi_awburst),
    .s_axi_awvalid(npu_csr_axi_awvalid),
    .s_axi_awready(npu_csr_axi_awready),
    .s_axi_wid(npu_csr_axi_wid),
    .s_axi_wdata(npu_csr_axi_wdata),
    .s_axi_wstrb(npu_csr_axi_wstrb),
    .s_axi_wlast(npu_csr_axi_wlast),
    .s_axi_wvalid(npu_csr_axi_wvalid),
    .s_axi_wready(npu_csr_axi_wready),
    .s_axi_bid(npu_csr_axi_bid),
    .s_axi_bresp(npu_csr_axi_bresp),
    .s_axi_bvalid(npu_csr_axi_bvalid),
    .s_axi_bready(npu_csr_axi_bready),
    .s_axi_arid(npu_csr_axi_arid),
    .s_axi_araddr(npu_csr_axi_araddr),
    .s_axi_arlen(npu_csr_axi_arlen),
    .s_axi_arsize(npu_csr_axi_arsize),
    .s_axi_arburst(npu_csr_axi_arburst),
    .s_axi_arvalid(npu_csr_axi_arvalid),
    .s_axi_arready(npu_csr_axi_arready),
    .s_axi_rid(npu_csr_axi_rid),
    .s_axi_rdata(npu_csr_axi_rdata),
    .s_axi_rresp(npu_csr_axi_rresp),
    .s_axi_rlast(npu_csr_axi_rlast),
    .s_axi_rvalid(npu_csr_axi_rvalid),
    .s_axi_rready(npu_csr_axi_rready)
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
    .dma_s_awaddr  (dma_csr_lite_awaddr),
    .dma_s_awprot  (dma_csr_lite_awprot),
    .dma_s_awvalid (dma_csr_lite_awvalid),
    .dma_s_awready (dma_csr_lite_awready),
    .dma_s_wdata   (dma_csr_lite_wdata),
    .dma_s_wstrb   (dma_csr_lite_wstrb),
    .dma_s_wvalid  (dma_csr_lite_wvalid),
    .dma_s_wready  (dma_csr_lite_wready),
    .dma_s_bresp   (dma_csr_lite_bresp),
    .dma_s_bvalid  (dma_csr_lite_bvalid),
    .dma_s_bready  (dma_csr_lite_bready),
    .dma_s_araddr  (dma_csr_lite_araddr),
    .dma_s_arprot  (dma_csr_lite_arprot),
    .dma_s_arvalid (dma_csr_lite_arvalid),
    .dma_s_arready (dma_csr_lite_arready),
    .dma_s_rdata   (dma_csr_lite_rdata),
    .dma_s_rresp   (dma_csr_lite_rresp),
    .dma_s_rvalid  (dma_csr_lite_rvalid),
    .dma_s_rready  (dma_csr_lite_rready),
    .dma_s_wlast   (1'b1),// AXI4-Lite 固定为 1
    .dma_s_rlast   (),// 输出，悬空

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
  // NPU Top 实例
  // ==========================================================
  npu_top #(
    .AXI_ID_W(AXI_ID_W), .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(32), .RAM_AXI_DATA_W(NPU_AXI_DATA_W),
    .MAX_M(4), .MAX_K(5), .BLOCK(4), .BATCH_COUNT(144), .CORE_NUM(40), .GROUP_NUM(5), .LANE_NUM(8),
    .IMG_W(28), .IMG_H(28), .WIN_W(5), .WIN_H(5), .CH_NUM(30), .POOL_W(12),
    .FC1_OUT(100), .FC2_OUT(10), .FC1_PAR(4), .FC2_IN_PAR(20), .FC1_BANKS(10),
    .FC1_BANK_OUT(10), .FC1_BANKS_PER_CYCLE(2),
    .RAM_DEPTH(1024), .B_RAM_BASE(256)
  ) u_npu_top (
    .clk(clk), .rst_n(resetn),
    // CSR AXI-Lite
    .s_awvalid(npu_csr_lite_awvalid), .s_awready(npu_csr_lite_awready),
    .s_awaddr(npu_csr_lite_awaddr), .s_awlen(8'd0), .s_awsize(3'b010), .s_awburst(2'b01),
    .s_awid(8'd0),
    .s_wvalid(npu_csr_lite_wvalid), .s_wready(npu_csr_lite_wready),
    .s_wdata(npu_csr_lite_wdata), .s_wstrb(npu_csr_lite_wstrb), .s_wlast(1'b1),
    .s_bvalid(npu_csr_lite_bvalid), .s_bready(npu_csr_lite_bready),
    .s_bresp(npu_csr_lite_bresp), .s_bid(),
    .s_arvalid(npu_csr_lite_arvalid), .s_arready(npu_csr_lite_arready),
    .s_araddr(npu_csr_lite_araddr), .s_arlen(8'd0), .s_arsize(3'b010), .s_arburst(2'b01),
    .s_arid(8'd0),
    .s_rvalid(npu_csr_lite_rvalid), .s_rready(npu_csr_lite_rready),
    .s_rdata(npu_csr_lite_rdata), .s_rresp(npu_csr_lite_rresp), .s_rlast(), .s_rid(),
    // NPU RAM AXI
    .ram_awvalid(npu_ram_awvalid), .ram_awready(npu_ram_awready),
    .ram_awaddr(npu_ram_awaddr), .ram_awlen(npu_ram_awlen), .ram_awsize(npu_ram_awsize),
    .ram_awburst(npu_ram_awburst), .ram_awlock(npu_ram_awlock), .ram_awcache(npu_ram_awcache),
    .ram_awprot(npu_ram_awprot), .ram_awqos(npu_ram_awqos), .ram_awregion(npu_ram_awregion),
    .ram_awid(npu_ram_awid), .ram_awuser(1'b0),
    .ram_wvalid(npu_ram_wvalid), .ram_wready(npu_ram_wready),
    .ram_wdata(npu_ram_wdata), .ram_wstrb(npu_ram_wstrb), .ram_wlast(npu_ram_wlast), .ram_wuser(1'b0),
    .ram_bvalid(npu_ram_bvalid), .ram_bready(npu_ram_bready),
    .ram_bid(npu_ram_bid), .ram_bresp(npu_ram_bresp), .ram_buser(),
    .ram_arvalid(npu_ram_arvalid), .ram_arready(npu_ram_arready),
    .ram_araddr(npu_ram_araddr), .ram_arlen(npu_ram_arlen), .ram_arsize(npu_ram_arsize),
    .ram_arburst(npu_ram_arburst), .ram_arlock(npu_ram_arlock), .ram_arcache(npu_ram_arcache),
    .ram_arprot(npu_ram_arprot), .ram_arqos(npu_ram_arqos), .ram_arregion(npu_ram_arregion),
    .ram_arid(npu_ram_arid), .ram_aruser(1'b0),
    .ram_rvalid(npu_ram_rvalid), .ram_rready(npu_ram_rready),
    .ram_rid(npu_ram_rid), .ram_rdata(npu_ram_rdata), .ram_rresp(npu_ram_rresp),
    .ram_rlast(npu_ram_rlast), .ram_ruser(),
    .fc2_valid(fc2_valid), .logits_out(logits_out), .pred_class(pred_class)
  );

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
    .MST0_ROUTES(4'b1100), // CPU 连接到从设备 2/3 (DMA CSR 和 NPU REG)，不连接到 DDR 和 NPU LMEM
    .MST0_ID_MASK(8'h10),.MST0_DATA_RATIO(5),

    // 主设备 1: DMA (ID mask 0x20)
    .MST1_CDC(0), .MST1_OSTDREQ_NUM(4), .MST1_OSTDREQ_SIZE(1), .MST1_PRIORITY(0),
    .MST1_ROUTES(4'b0010), // DMA 连接到从设备 1 (NPU LMEM)，不连接到 DDR、DMA CSR 和 NPU REG
    .MST1_ID_MASK(8'h20),.MST1_DATA_RATIO(1),

    // 主设备 2/3 未使用
    .MST2_CDC(0), .MST2_OSTDREQ_NUM(1), .MST2_OSTDREQ_SIZE(1), .MST2_PRIORITY(0),
    .MST2_ROUTES(4'b0000), .MST2_ID_MASK(8'h30), .MST2_DATA_RATIO(5),
    .MST3_CDC(0), .MST3_OSTDREQ_NUM(1), .MST3_OSTDREQ_SIZE(1), .MST3_PRIORITY(0),
    .MST3_ROUTES(4'b0000), .MST3_ID_MASK(8'h40), .MST3_DATA_RATIO(5),

    // 从设备 0: unused (0x4000_0000 - 0x43FF_FFFF)
    .SLV0_CDC(0), .SLV0_START_ADDR(32'h4000_0000), .SLV0_END_ADDR(32'h43FF_FFFF),
    .SLV0_OSTDREQ_NUM(4), .SLV0_OSTDREQ_SIZE(1), .SLV0_KEEP_BASE_ADDR(0),.SLV0_DATA_RATIO(5),

    // 从设备 1: NPU LMEM (0x0000_1000 - 0x0002_0FFF)
    .SLV1_CDC(0), .SLV1_START_ADDR(32'h0000_1000), .SLV1_END_ADDR(32'h0002_0FFF),
    .SLV1_OSTDREQ_NUM(4), .SLV1_OSTDREQ_SIZE(1), .SLV1_KEEP_BASE_ADDR(1),.SLV1_DATA_RATIO(1),

    // 从设备 2: DMA CSR (0x0002_1000 - 0x0002_1FFF)
    .SLV2_CDC(0), .SLV2_START_ADDR(32'h0002_1000), .SLV2_END_ADDR(32'h0002_1FFF),
    .SLV2_OSTDREQ_NUM(4), .SLV2_OSTDREQ_SIZE(1), .SLV2_KEEP_BASE_ADDR(0),.SLV2_DATA_RATIO(5),

    // 从设备 3: NPU REG (0x0002_0000 - 0x0002_0FFF)
    .SLV3_CDC(0), .SLV3_START_ADDR(32'h0002_0000), .SLV3_END_ADDR(32'h0002_0FFF),
    .SLV3_OSTDREQ_NUM(4), .SLV3_OSTDREQ_SIZE(1), .SLV3_KEEP_BASE_ADDR(0),.SLV3_DATA_RATIO(5)
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

    //从设备0置空，不连接DDR，避免时序问题
    // Master 0: DDR
    .mst0_aclk(clk), .mst0_aresetn(resetn), .mst0_srst(rst),
    .mst0_awvalid(), .mst0_awready(1'b0),
    .mst0_awaddr(), .mst0_awlen(), .mst0_awsize(),
    .mst0_awburst(), .mst0_awlock(),
    .mst0_awcache(), .mst0_awprot(),
    .mst0_awqos(), .mst0_awregion(),
    .mst0_awid(), .mst0_awuser(),
    .mst0_wvalid(), .mst0_wready(1'b0),
    .mst0_wlast(), .mst0_wdata(), .mst0_wstrb(),
    .mst0_wuser(),
    .mst0_bvalid(1'b0), .mst0_bready(),
    .mst0_bid('0), .mst0_bresp('0), .mst0_buser('0),
    .mst0_arvalid(), .mst0_arready(1'b0),
    .mst0_araddr(), .mst0_arlen(), .mst0_arsize(),
    .mst0_arburst(), .mst0_arlock(),
    .mst0_arcache(), .mst0_arprot(),
    .mst0_arqos(), .mst0_arregion(),
    .mst0_arid(), .mst0_aruser(),
    .mst0_rvalid(), .mst0_rready(),
    .mst0_rid('0), .mst0_rresp('0), .mst0_rdata('0),
    .mst0_rlast(1'b0), .mst0_ruser(1'b0),
    
    // Master 1: NPU LMEM
    .mst1_aclk(clk), .mst1_aresetn(resetn), .mst1_srst(rst),
    .mst1_awvalid(npu_ram_awvalid), .mst1_awready(npu_ram_awready),
    .mst1_awaddr(npu_ram_awaddr), .mst1_awlen(npu_ram_awlen), .mst1_awsize(npu_ram_awsize),
    .mst1_awburst(npu_ram_awburst), .mst1_awlock(npu_ram_awlock),
    .mst1_awcache(npu_ram_awcache), .mst1_awprot(npu_ram_awprot),
    .mst1_awqos(npu_ram_awqos), .mst1_awregion(npu_ram_awregion),
    .mst1_awid(npu_ram_awid), .mst1_awuser(),
    .mst1_wvalid(npu_ram_wvalid), .mst1_wready(npu_ram_wready),
    .mst1_wlast(npu_ram_wlast), .mst1_wdata(npu_ram_wdata), .mst1_wstrb(npu_ram_wstrb),
    .mst1_wuser(),
    .mst1_bvalid(npu_ram_bvalid), .mst1_bready(npu_ram_bready),
    .mst1_bid(npu_ram_bid), .mst1_bresp(npu_ram_bresp), .mst1_buser(1'b0),
    .mst1_arvalid(npu_ram_arvalid), .mst1_arready(npu_ram_arready),
    .mst1_araddr(npu_ram_araddr), .mst1_arlen(npu_ram_arlen), .mst1_arsize(npu_ram_arsize),
    .mst1_arburst(npu_ram_arburst), .mst1_arlock(npu_ram_arlock),
    .mst1_arcache(npu_ram_arcache), .mst1_arprot(npu_ram_arprot),
    .mst1_arqos(npu_ram_arqos), .mst1_arregion(npu_ram_arregion),
    .mst1_arid(npu_ram_arid), .mst1_aruser(),
    .mst1_rvalid(npu_ram_rvalid), .mst1_rready(npu_ram_rready),
    .mst1_rid(npu_ram_rid), .mst1_rresp(npu_ram_rresp), .mst1_rdata(npu_ram_rdata),
    .mst1_rlast(npu_ram_rlast), .mst1_ruser(1'b0),

    // Master 2: DMA CSR (经过桥)
    .mst2_aclk(clk), .mst2_aresetn(resetn), .mst2_srst(rst),
    .mst2_awvalid(dma_csr_axi_awvalid), .mst2_awready(dma_csr_axi_awready),
    .mst2_awaddr(dma_csr_axi_awaddr), .mst2_awlen(dma_csr_axi_awlen), .mst2_awsize(dma_csr_axi_awsize),
    .mst2_awburst(dma_csr_axi_awburst), .mst2_awlock(dma_csr_axi_awlock),
    .mst2_awcache(dma_csr_axi_awcache), .mst2_awprot(dma_csr_axi_awprot),
    .mst2_awqos(dma_csr_axi_awqos), .mst2_awregion(dma_csr_axi_awregion),
    .mst2_awid(dma_csr_axi_awid), .mst2_awuser(),
    .mst2_wvalid(dma_csr_axi_wvalid), .mst2_wready(dma_csr_axi_wready),
    .mst2_wlast(dma_csr_axi_wlast), .mst2_wdata(dma_csr_axi_wdata), .mst2_wstrb(dma_csr_axi_wstrb),
    .mst2_wuser(),
    .mst2_bvalid(dma_csr_axi_bvalid), .mst2_bready(dma_csr_axi_bready),
    .mst2_bid(dma_csr_axi_bid), .mst2_bresp(dma_csr_axi_bresp), .mst2_buser(1'b0),
    .mst2_arvalid(dma_csr_axi_arvalid), .mst2_arready(dma_csr_axi_arready),
    .mst2_araddr(dma_csr_axi_araddr), .mst2_arlen(dma_csr_axi_arlen), .mst2_arsize(dma_csr_axi_arsize),
    .mst2_arburst(dma_csr_axi_arburst), .mst2_arlock(dma_csr_axi_arlock),
    .mst2_arcache(dma_csr_axi_arcache), .mst2_arprot(dma_csr_axi_arprot),
    .mst2_arqos(dma_csr_axi_arqos), .mst2_arregion(dma_csr_axi_arregion),
    .mst2_arid(dma_csr_axi_arid), .mst2_aruser(),
    .mst2_rvalid(dma_csr_axi_rvalid), .mst2_rready(dma_csr_axi_rready),
    .mst2_rid(dma_csr_axi_rid), .mst2_rresp(dma_csr_axi_rresp), .mst2_rdata(dma_csr_axi_rdata),
    .mst2_rlast(dma_csr_axi_rlast), .mst2_ruser(1'b0),

    // Master 3: NPU CSR (经过桥)
    .mst3_aclk(clk), .mst3_aresetn(resetn), .mst3_srst(rst),
    .mst3_awvalid(npu_csr_axi_awvalid), .mst3_awready(npu_csr_axi_awready),
    .mst3_awaddr(npu_csr_axi_awaddr), .mst3_awlen(npu_csr_axi_awlen), .mst3_awsize(npu_csr_axi_awsize),
    .mst3_awburst(npu_csr_axi_awburst), .mst3_awlock(npu_csr_axi_awlock),
    .mst3_awcache(npu_csr_axi_awcache), .mst3_awprot(npu_csr_axi_awprot),
    .mst3_awqos(npu_csr_axi_awqos), .mst3_awregion(npu_csr_axi_awregion),
    .mst3_awid(npu_csr_axi_awid), .mst3_awuser(),
    .mst3_wvalid(npu_csr_axi_wvalid), .mst3_wready(npu_csr_axi_wready),
    .mst3_wlast(npu_csr_axi_wlast), .mst3_wdata(npu_csr_axi_wdata), .mst3_wstrb(npu_csr_axi_wstrb),
    .mst3_wuser(),
    .mst3_bvalid(npu_csr_axi_bvalid), .mst3_bready(npu_csr_axi_bready),
    .mst3_bid(npu_csr_axi_bid), .mst3_bresp(npu_csr_axi_bresp), .mst3_buser(1'b0),
    .mst3_arvalid(npu_csr_axi_arvalid), .mst3_arready(npu_csr_axi_arready),
    .mst3_araddr(npu_csr_axi_araddr), .mst3_arlen(npu_csr_axi_arlen), .mst3_arsize(npu_csr_axi_arsize),
    .mst3_arburst(npu_csr_axi_arburst), .mst3_arlock(npu_csr_axi_arlock),
    .mst3_arcache(npu_csr_axi_arcache), .mst3_arprot(npu_csr_axi_arprot),
    .mst3_arqos(npu_csr_axi_arqos), .mst3_arregion(npu_csr_axi_arregion),
    .mst3_arid(npu_csr_axi_arid), .mst3_aruser(),
    .mst3_rvalid(npu_csr_axi_rvalid), .mst3_rready(npu_csr_axi_rready),
    .mst3_rid(npu_csr_axi_rid), .mst3_rresp(npu_csr_axi_rresp), .mst3_rdata(npu_csr_axi_rdata),
    .mst3_rlast(npu_csr_axi_rlast), .mst3_ruser(1'b0)
  );


  // ==========================================================
  // DMA 测试
  // ==========================================================
  task automatic wait_dma_done();
    fork
      begin wait(dma_done == 1'b1); end
      begin #2ms; $error("[TEST] TIMEOUT waiting for dma_done"); $stop; end
    join_any
    disable fork;
    #1;
  endtask


// DMA搬运图像数据喂给NPU

    initial begin : DMA_TEST
    automatic int i;
    automatic int beat_bytes = AXI_DATA_W / 8;               // 20
    automatic int target_word_offset = (NPU_DST_ADDR) / beat_bytes; // 0x1400 / 20 = 160
    logic [AXI_DATA_W-1:0] dma_rom [0:719];
    bit mismatch;

    // 1. 获取 DMA 内部 ROM 数据（用于校验）
    force dma_rom = u_dma.u_dma_axi_wrapper.u_dma_func_wrapper.u_dma_rom_reader.mem;

    // 2. 等待复位释放
    @(negedge rst);
    repeat (10) @(posedge clk);

    // 3. 启动 NPU —— 直接 force 内部 npu_start 信号产生一个时钟周期的高脉冲
    $display("[TB] Starting NPU (force npu_start)");
    force u_npu_top.u_csr.npu_start = 1'b1;
    @(posedge clk);
    release u_npu_top.u_csr.npu_start;

    // 4. 立即配置并启动 DMA（NPU 需要 40 个周期预加载权重，DMA 利用此窗口写入数据）
    $display("[TB] Configuring DMA...");
    force u_dma.u_dma_axi_wrapper.u_dma_csr.reg_src_addr[0]  = 32'h8000_0000;
    force u_dma.u_dma_axi_wrapper.u_dma_csr.reg_dst_addr[0]  = NPU_DST_ADDR;
    force u_dma.u_dma_axi_wrapper.u_dma_csr.reg_num_bytes[0] = DMA_BYTES;
    force u_dma.u_dma_axi_wrapper.u_dma_csr.reg_wr_mode[0]   = 1'b0;
    force u_dma.u_dma_axi_wrapper.u_dma_csr.reg_rd_mode[0]   = 1'b1;
    force u_dma.u_dma_axi_wrapper.u_dma_csr.reg_enable[0]    = 1'b1;
    force u_dma.u_dma_axi_wrapper.u_dma_csr.reg_max_burst    = 8'd255;
    force u_dma.u_dma_axi_wrapper.u_dma_csr.reg_abort        = 1'b0;
    force u_dma.u_dma_axi_wrapper.u_dma_csr.reg_go           = 1'b0;
    repeat (3) @(posedge clk);
    force u_dma.u_dma_axi_wrapper.u_dma_csr.reg_go = 1'b1;
    $display("[TB] DMA started");

    // 5. 等待 DMA 完成
    wait_dma_done();

    // 6. 等待 NPU 推理完成（轮询 fc2_valid 或 done）
    while (!fc2_valid) @(posedge clk);
    for(i = 0; i < 10; i++) begin
      $display("final_logit[%0d] = %0d", i, $signed(logits_out[(i*32) +: 32]));
    end
    $display("[TB] NPU done, pred_class = %0d", pred_class);

    // 7. 释放 DMA force（NPU_start 已释放）
    release u_dma.u_dma_axi_wrapper.u_dma_csr.reg_src_addr[0];
    release u_dma.u_dma_axi_wrapper.u_dma_csr.reg_dst_addr[0];
    release u_dma.u_dma_axi_wrapper.u_dma_csr.reg_num_bytes[0];
    release u_dma.u_dma_axi_wrapper.u_dma_csr.reg_wr_mode[0];
    release u_dma.u_dma_axi_wrapper.u_dma_csr.reg_rd_mode[0];
    release u_dma.u_dma_axi_wrapper.u_dma_csr.reg_enable[0];
    release u_dma.u_dma_axi_wrapper.u_dma_csr.reg_max_burst;
    release u_dma.u_dma_axi_wrapper.u_dma_csr.reg_abort;
    release u_dma.u_dma_axi_wrapper.u_dma_csr.reg_go;

    // 8. 数据校验
    for (i = 0; i < DMA_BYTES / beat_bytes; i++) begin
      logic [AXI_DATA_W-1:0] exp_data, got_data;
      exp_data = dma_rom[i];
      got_data = u_npu_top.u_npu_ram.mem[target_word_offset + i];
      //$display("[TB] DMA CARRY AFTER: %0d: exp=%040x      %0d: got=%040x", i, exp_data, target_word_offset + i, got_data);
      if (exp_data !== got_data) begin
        mismatch = 1;
        $display("[TB] MISMATCH at word %0d: exp=%040x got=%040x", i, exp_data, got_data);
      end
    end

    if (dma_error)         $error("[TB] FAIL: DMA error");
    else if (!dma_done)    $error("[TB] FAIL: DMA not done");
    else if (mismatch)     $error("[TB] FAIL: Data mismatch");
    else                   $display("[TB] PASS: DMA and NPU collaborated successfully.");

    $stop;
  end

  initial begin
    $dumpfile("tb_soc.vcd");
    $dumpvars(0, tb_soc);
  end
endmodule
`default_nettype wire