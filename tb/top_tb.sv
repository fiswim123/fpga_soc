`timescale 1ns/1ps
`include "../src/inc/amba_axi.svh"
`include "../src/inc/dma_pkg.svh"

module top_tb;
  import amba_axi_pkg::*;
  import dma_utils_pkg::*;

  localparam logic [31:0] LOCAL_ROM_BASE = 32'h0000_0000;
  localparam int          LOCAL_ROM_AW   = 12;
  localparam logic [31:0] LOCAL_RAM_BASE = 32'h1000_0000;
  localparam int          LOCAL_RAM_AW   = 12;

  localparam logic [31:0] DMA_CSR_BASE   = 32'h2000_0000;
  localparam logic [31:0] DMA_CSR_MASK   = 32'hFFFF_F000;

  localparam logic [31:0] DDR_BASE       = 32'h4000_0000;
  localparam int          DDR_SIZE_BYTES = 67108864;

  logic clk, rst, resetn;
  initial begin clk=0; forever #5 clk=~clk; end
  initial begin rst=1; #100 rst=0; end
  assign resetn = ~rst;

  // ---------------- CPU AXI-Lite ----------------
  logic        cpu_axi_awvalid, cpu_axi_awready;
  logic [31:0] cpu_axi_awaddr;
  logic [2:0]  cpu_axi_awprot;
  logic        cpu_axi_wvalid, cpu_axi_wready;
  logic [31:0] cpu_axi_wdata;
  logic [3:0]  cpu_axi_wstrb;
  logic        cpu_axi_bvalid, cpu_axi_bready;
  logic        cpu_axi_arvalid, cpu_axi_arready;
  logic [31:0] cpu_axi_araddr;
  logic [2:0]  cpu_axi_arprot;
  logic        cpu_axi_rvalid, cpu_axi_rready;
  logic [31:0] cpu_axi_rdata;
  logic        cpu_trap;

  logic        pcpi_wr, pcpi_wait, pcpi_ready;
  logic [31:0] pcpi_rd, irq, eoi;
  logic        trace_valid, pcpi_valid;
  logic [35:0] trace_data;
  logic [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2;
  assign pcpi_wr=0; assign pcpi_rd=0; assign pcpi_wait=0; assign pcpi_ready=0; assign irq=0;

  parameter [8*128-1:0] LOCAL_ROM_INIT_FILE = "../src/instr_data.dat";
  parameter [8*128-1:0] DDR_INIT_FILE = "../src/mnist.hex";


  picorv32_axi #(
    .PROGADDR_RESET       (32'h0000_0000),
    .PROGADDR_IRQ         (32'h0000_0010),
    .LOCAL_ROM_BASE       (LOCAL_ROM_BASE),
    .LOCAL_ROM_ADDR_WIDTH (LOCAL_ROM_AW),
    .LOCAL_RAM_BASE       (LOCAL_RAM_BASE),
    .LOCAL_RAM_ADDR_WIDTH (LOCAL_RAM_AW),
    .LOCAL_ROM_INIT_FILE  (LOCAL_ROM_INIT_FILE)
  ) u_cpu (
    .clk(clk), .resetn(resetn), .trap(cpu_trap),
    .mem_axi_awvalid(cpu_axi_awvalid), .mem_axi_awready(cpu_axi_awready), .mem_axi_awaddr(cpu_axi_awaddr), .mem_axi_awprot(cpu_axi_awprot),
    .mem_axi_wvalid(cpu_axi_wvalid), .mem_axi_wready(cpu_axi_wready), .mem_axi_wdata(cpu_axi_wdata), .mem_axi_wstrb(cpu_axi_wstrb),
    .mem_axi_bvalid(cpu_axi_bvalid), .mem_axi_bready(cpu_axi_bready),
    .mem_axi_arvalid(cpu_axi_arvalid), .mem_axi_arready(cpu_axi_arready), .mem_axi_araddr(cpu_axi_araddr), .mem_axi_arprot(cpu_axi_arprot),
    .mem_axi_rvalid(cpu_axi_rvalid), .mem_axi_rready(cpu_axi_rready), .mem_axi_rdata(cpu_axi_rdata),
    .pcpi_valid(pcpi_valid), .pcpi_insn(pcpi_insn), .pcpi_rs1(pcpi_rs1), .pcpi_rs2(pcpi_rs2),
    .pcpi_wr(pcpi_wr), .pcpi_rd(pcpi_rd), .pcpi_wait(pcpi_wait), .pcpi_ready(pcpi_ready),
    .irq(irq), .eoi(eoi), .trace_valid(trace_valid), .trace_data(trace_data)
  );

  // ---------------- DMA CSR slave ----------------
  logic dma_s_awvalid,dma_s_awready,dma_s_wvalid,dma_s_wready,dma_s_bvalid,dma_s_bready;
  logic dma_s_arvalid,dma_s_arready,dma_s_rvalid,dma_s_rready;
  logic [31:0] dma_s_awaddr,dma_s_wdata,dma_s_araddr,dma_s_rdata;
  logic [3:0]  dma_s_wstrb;
  axi_prot_t   dma_s_awprot,dma_s_arprot;
  axi_resp_t   dma_s_bresp,dma_s_rresp;

  // ---------------- DMA master -> DDR ----------------
  logic dma_m_awvalid,dma_m_awready,dma_m_wvalid,dma_m_wready,dma_m_bvalid,dma_m_bready;
  logic dma_m_arvalid,dma_m_arready,dma_m_rvalid,dma_m_rready,dma_m_wlast,dma_m_rlast;
  logic [7:0] dma_m_awid,dma_m_bid,dma_m_arid,dma_m_rid,dma_m_awlen,dma_m_arlen;
  logic [2:0] dma_m_awsize,dma_m_arsize;
  logic [1:0] dma_m_awburst,dma_m_arburst;
  logic dma_m_awlock,dma_m_arlock;
  logic [3:0] dma_m_awcache,dma_m_arcache,dma_m_awqos,dma_m_arqos,dma_m_awregion,dma_m_arregion;
  logic [0:0] dma_m_awuser,dma_m_wuser,dma_m_buser,dma_m_aruser,dma_m_ruser;
  logic [31:0] dma_m_awaddr,dma_m_wdata,dma_m_araddr,dma_m_rdata;
  logic [3:0]  dma_m_wstrb;
  axi_prot_t   dma_m_awprot,dma_m_arprot;
  axi_resp_t   dma_m_bresp,dma_m_rresp;

  logic dma_done_o, dma_error_o;

  // CPU -> DMA CSR decode
  wire hit_dma_aw = ((cpu_axi_awaddr & DMA_CSR_MASK) == DMA_CSR_BASE);
  wire hit_dma_ar = ((cpu_axi_araddr & DMA_CSR_MASK) == DMA_CSR_BASE);

  assign dma_s_awvalid = cpu_axi_awvalid && hit_dma_aw;
  assign dma_s_awaddr  = cpu_axi_awaddr - DMA_CSR_BASE;
  assign dma_s_awprot  = axi_prot_t'(cpu_axi_awprot);
  assign dma_s_wvalid  = cpu_axi_wvalid && hit_dma_aw;
  assign dma_s_wdata   = cpu_axi_wdata;
  assign dma_s_wstrb   = cpu_axi_wstrb;
  assign dma_s_bready  = cpu_axi_bready;

  assign dma_s_arvalid = cpu_axi_arvalid && hit_dma_ar;
  assign dma_s_araddr  = cpu_axi_araddr - DMA_CSR_BASE;
  assign dma_s_arprot  = axi_prot_t'(cpu_axi_arprot);
  assign dma_s_rready  = cpu_axi_rready;

  // 对未命中地址返回“空响应”
  assign cpu_axi_awready = hit_dma_aw ? dma_s_awready : 1'b1;
  assign cpu_axi_wready  = hit_dma_aw ? dma_s_wready  : 1'b1;
  assign cpu_axi_bvalid  = hit_dma_aw ? dma_s_bvalid  : (cpu_axi_awvalid && cpu_axi_wvalid);
  assign cpu_axi_arready = hit_dma_ar ? dma_s_arready : 1'b1;
  assign cpu_axi_rvalid  = hit_dma_ar ? dma_s_rvalid  : cpu_axi_arvalid;
  assign cpu_axi_rdata   = hit_dma_ar ? dma_s_rdata   : 32'h0;

  dma_axi_top dut (
    .clk(clk), .rst(rst), .dma_done_o(dma_done_o), .dma_error_o(dma_error_o),
    .dma_s_awaddr(dma_s_awaddr), .dma_s_awprot(dma_s_awprot), .dma_s_awvalid(dma_s_awvalid), .dma_s_awready(dma_s_awready),
    .dma_s_wdata(dma_s_wdata), .dma_s_wstrb(dma_s_wstrb), .dma_s_wvalid(dma_s_wvalid), .dma_s_wready(dma_s_wready),
    .dma_s_bresp(dma_s_bresp), .dma_s_bvalid(dma_s_bvalid), .dma_s_bready(dma_s_bready),
    .dma_s_araddr(dma_s_araddr), .dma_s_arprot(dma_s_arprot), .dma_s_arvalid(dma_s_arvalid), .dma_s_arready(dma_s_arready),
    .dma_s_rdata(dma_s_rdata), .dma_s_rresp(dma_s_rresp), .dma_s_rvalid(dma_s_rvalid), .dma_s_rready(dma_s_rready),
    .dma_s_wlast(1'b0), .dma_s_rlast(),

    .dma_m_awid(dma_m_awid), .dma_m_awaddr(dma_m_awaddr), .dma_m_awlen(dma_m_awlen), .dma_m_awsize(dma_m_awsize), .dma_m_awburst(dma_m_awburst),
    .dma_m_awlock(dma_m_awlock), .dma_m_awcache(dma_m_awcache), .dma_m_awprot(dma_m_awprot), .dma_m_awqos(dma_m_awqos), .dma_m_awregion(dma_m_awregion),
    .dma_m_awuser(dma_m_awuser), .dma_m_awvalid(dma_m_awvalid),

    .dma_m_wdata(dma_m_wdata), .dma_m_wstrb(dma_m_wstrb), .dma_m_wlast(dma_m_wlast), .dma_m_wuser(dma_m_wuser), .dma_m_wvalid(dma_m_wvalid),
    .dma_m_bready(dma_m_bready),

    .dma_m_arid(dma_m_arid), .dma_m_araddr(dma_m_araddr), .dma_m_arlen(dma_m_arlen), .dma_m_arsize(dma_m_arsize), .dma_m_arburst(dma_m_arburst),
    .dma_m_arlock(dma_m_arlock), .dma_m_arcache(dma_m_arcache), .dma_m_arprot(dma_m_arprot), .dma_m_arqos(dma_m_arqos), .dma_m_arregion(dma_m_arregion),
    .dma_m_aruser(dma_m_aruser), .dma_m_arvalid(dma_m_arvalid), .dma_m_rready(dma_m_rready),

    .dma_m_awready(dma_m_awready), .dma_m_wready(dma_m_wready), .dma_m_bid(dma_m_bid), .dma_m_bresp(dma_m_bresp), .dma_m_buser(dma_m_buser), .dma_m_bvalid(dma_m_bvalid),
    .dma_m_arready(dma_m_arready), .dma_m_rid(dma_m_rid), .dma_m_rdata(dma_m_rdata), .dma_m_rresp(dma_m_rresp), .dma_m_rlast(dma_m_rlast), .dma_m_ruser(dma_m_ruser), .dma_m_rvalid(dma_m_rvalid)
  );

  ddr #(
    .DDR_SIZE_BYTES(DDR_SIZE_BYTES), .AXI_ID_W(8), .AXI_DATA_W(32), .AXI_ADDR_W(32), .DDR_BASE(DDR_BASE),.DDR_INIT_FILE(DDR_INIT_FILE)
  ) u_ddr (
    .clk(clk), .rst(rst),
    .s_awid(dma_m_awid), .s_awaddr(dma_m_awaddr), .s_awlen(dma_m_awlen), .s_awsize(dma_m_awsize), .s_awburst(dma_m_awburst),
    .s_awlock(dma_m_awlock), .s_awcache(dma_m_awcache), .s_awprot(dma_m_awprot), .s_awqos(dma_m_awqos), .s_awregion(dma_m_awregion), .s_awuser(dma_m_awuser), .s_awvalid(dma_m_awvalid), .s_awready(dma_m_awready),
    .s_wdata(dma_m_wdata), .s_wstrb(dma_m_wstrb), .s_wlast(dma_m_wlast), .s_wuser(dma_m_wuser), .s_wvalid(dma_m_wvalid), .s_wready(dma_m_wready),
    .s_bid(dma_m_bid), .s_bresp(dma_m_bresp), .s_buser(dma_m_buser), .s_bvalid(dma_m_bvalid), .s_bready(dma_m_bready),
    .s_arid(dma_m_arid), .s_araddr(dma_m_araddr), .s_arlen(dma_m_arlen), .s_arsize(dma_m_arsize), .s_arburst(dma_m_arburst),
    .s_arlock(dma_m_arlock), .s_arcache(dma_m_arcache), .s_arprot(dma_m_arprot), .s_arqos(dma_m_arqos), .s_arregion(dma_m_arregion), .s_aruser(dma_m_aruser), .s_arvalid(dma_m_arvalid), .s_arready(dma_m_arready),
    .s_rid(dma_m_rid), .s_rdata(dma_m_rdata), .s_rresp(dma_m_rresp), .s_rlast(dma_m_rlast), .s_ruser(dma_m_ruser), .s_rvalid(dma_m_rvalid), .s_rready(dma_m_rready)
  );

  initial begin : DMA_END2END_CHECK
  int i;
  int src_base, dst_base;
  bit mismatch;

  localparam int DMA_BYTES = 7840000; // 0x31A000, 7.84MB (MNIST全量数据大小)，测试时可调整为更小的值以加快仿真

  src_base = 32'h4000_0000 - DDR_BASE;
  dst_base = 32'h4080_0000 - DDR_BASE;
/*
  // 1) reset后预加载DDR
  @(negedge rst);
  @(posedge clk);

  for (i = 0; i < DMA_BYTES; i = i + 1) begin
    u_ddr.mem[src_base + i] = (8'h10 + i[7:0]); // SRC pattern
    u_ddr.mem[dst_base + i] = 8'h00;            // DST clear
  end

  $display("\n[TB] ===== PRELOAD DONE (DMA_BYTES=%0d / 0x%0h) =====", DMA_BYTES, DMA_BYTES);
  for (i = 0; i < 16; i = i + 1)
    $display("[TB] preload SRC[%0d]=%02x", i, u_ddr.mem[src_base + i]);
*/
  // 2) DMA前打印（只打印前64B，避免刷屏）
  repeat (5) @(posedge clk);
  $display("\n[TB] ===== BEFORE DMA COPY =====");
  $display("[TB] SRC @0x4001_0000 (first 64B):");
  for (i = 0; i < 64; i = i + 1) begin
    if ((i % 16) == 0) $write("  +0x%03x : ", i);
    $write("%02x ", u_ddr.mem[src_base + i]);
    if ((i % 16) == 15) $write("\n");
  end
  $display("[TB] DST @0x4002_0000 (first 64B):");
  for (i = 0; i < 64; i = i + 1) begin
    if ((i % 16) == 0) $write("  +0x%03x : ", i);
    $write("%02x ", u_ddr.mem[dst_base + i]);
    if ((i % 16) == 15) $write("\n");
  end

  // 3) 等待DMA结束
  wait(dma_done_o || dma_error_o || cpu_trap);
  #1;

  // 4) 打印DMA CSR
  $display("\n[DMA_CSR] SRC0      = 0x%08x", dut.u_dma_axi_wrapper.u_csr_dma.reg_src_addr[0]);
  $display("[DMA_CSR] DST0      = 0x%08x", dut.u_dma_axi_wrapper.u_csr_dma.reg_dst_addr[0]);
  $display("[DMA_CSR] NUM0      = 0x%08x", dut.u_dma_axi_wrapper.u_csr_dma.reg_num_bytes[0]);
  $display("[DMA_CSR] CFG0 wr/rd/en = %0b/%0b/%0b",
           dut.u_dma_axi_wrapper.u_csr_dma.reg_wr_mode[0],
           dut.u_dma_axi_wrapper.u_csr_dma.reg_rd_mode[0],
           dut.u_dma_axi_wrapper.u_csr_dma.reg_enable[0]);
  $display("[DMA_CSR] CTRL go/abort/max_burst = %0b/%0b/0x%02x",
           dut.u_dma_axi_wrapper.u_csr_dma.reg_go,
           dut.u_dma_axi_wrapper.u_csr_dma.reg_abort,
           dut.u_dma_axi_wrapper.u_csr_dma.reg_max_burst);

  // 5) DMA后打印（前64B）
  $display("\n[TB] ===== AFTER DMA COPY =====");
  $display("[TB] status: trap=%0b done=%0b err=%0b", cpu_trap, dma_done_o, dma_error_o);
  $display("[TB] SRC @0x4001_0000 (first 64B):");
  for (i = 0; i < 64; i = i + 1) begin
    if ((i % 16) == 0) $write("  +0x%03x : ", i);
    $write("%02x ", u_ddr.mem[src_base + i]);
    if ((i % 16) == 15) $write("\n");
  end
  $display("[TB] DST @0x4002_0000 (first 64B):");
  for (i = 0; i < 64; i = i + 1) begin
    if ((i % 16) == 0) $write("  +0x%03x : ", i);
    $write("%02x ", u_ddr.mem[dst_base + i]);
    if ((i % 16) == 15) $write("\n");
  end

  // 6) 全量校验 DMA_BYTES
  mismatch = 0;
  for (i = 0; i < DMA_BYTES; i = i + 1) begin
    if (u_ddr.mem[src_base + i] !== u_ddr.mem[dst_base + i]) begin
      mismatch = 1;
      $display("[TB] MISMATCH byte[%0d] SRC=%02x DST=%02x",
               i, u_ddr.mem[src_base + i], u_ddr.mem[dst_base + i]);
    end
  end

  if (cpu_trap)           $error("[TB] FAIL: cpu_trap");
  else if (dma_error_o)   $error("[TB] FAIL: dma_error_o");
  else if (!dma_done_o)   $error("[TB] FAIL: dma_done_o not asserted");
  else if (mismatch)      $error("[TB] FAIL: SRC/DST mismatch");
  else                    $display("[TB] PASS: DMA copied %0d bytes.", DMA_BYTES);

  $stop;
end
endmodule