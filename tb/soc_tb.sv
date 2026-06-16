`timescale 1ns/1ps
`default_nettype none

module soc_tb;

  localparam logic [31:0] DDR_BASE      = 32'h4000_0000;
  localparam logic [31:0] NPU_LMEM_BASE = 32'h0000_1000;
  localparam logic [31:0] NPU_CSR_BASE  = 32'h0002_0000;
  localparam logic [31:0] DMA_CSR_BASE  = 32'h0002_1000;

  // 时钟与复位
  logic clk, rst;
  initial begin clk=0; forever #5 clk=~clk; end
  initial begin rst=1; #100 rst=0; end

  // DUT
  logic dma_done, dma_error, cpu_trap;
  soc_top #(.DDR_INIT_FILE("")) u_soc (
    .clk(clk), .rst(rst),
    .dma_done_o(dma_done), .dma_error_o(dma_error), .cpu_trap_o(cpu_trap)
  );

  // 便捷宏
  `define DDR_MEM u_soc.u_ddr.mem
  `define NPU_MEM u_soc.u_npu_ram.mem

  // 内存直接读写
  task ddr_write32(input logic[31:0] addr, input logic[31:0] data);
    int b; b = addr - DDR_BASE;
    `DDR_MEM[b+3]=data[31:24]; `DDR_MEM[b+2]=data[23:16]; `DDR_MEM[b+1]=data[15:8]; `DDR_MEM[b+0]=data[7:0];
  endtask
  task ddr_read32(input logic[31:0] addr, output logic[31:0] data);
    int b; b = addr - DDR_BASE;
    data = {`DDR_MEM[b+3],`DDR_MEM[b+2],`DDR_MEM[b+1],`DDR_MEM[b+0]};
  endtask
  task npu_write32(input logic[31:0] addr, input logic[31:0] data);
    int b; b = addr - NPU_LMEM_BASE;
    `NPU_MEM[b+3]=data[31:24]; `NPU_MEM[b+2]=data[23:16]; `NPU_MEM[b+1]=data[15:8]; `NPU_MEM[b+0]=data[7:0];
  endtask
  task npu_read32(input logic[31:0] addr, output logic[31:0] data);
    int b; b = addr - NPU_LMEM_BASE;
    data = {`NPU_MEM[b+3],`NPU_MEM[b+2],`NPU_MEM[b+1],`NPU_MEM[b+0]};
  endtask

  // NPU CSR 直接写
  task npu_csr_write(input logic[7:0] ofs, input logic[31:0] data);
    case(ofs)
      8'h00: force u_soc.u_csr_npu.reg_ctrl = data;
      8'h04: force u_soc.u_csr_npu.reg_status = data;
      8'h08: force u_soc.u_csr_npu.reg_src = data;
      8'h0C: force u_soc.u_csr_npu.reg_dst = data;
      8'h10: force u_soc.u_csr_npu.reg_len = data;
      8'h14: force u_soc.u_csr_npu.reg_cfg = data;
    endcase
    repeat(5) @(posedge clk);
    case(ofs)
      8'h00: release u_soc.u_csr_npu.reg_ctrl;
      8'h04: release u_soc.u_csr_npu.reg_status;
      8'h08: release u_soc.u_csr_npu.reg_src;
      8'h0C: release u_soc.u_csr_npu.reg_dst;
      8'h10: release u_soc.u_csr_npu.reg_len;
      8'h14: release u_soc.u_csr_npu.reg_cfg;
    endcase
  endtask

  // DMA AXI-Lite slave 端口写（force DMA 输入端口）
  task dma_axil_write(input logic[31:0] addr, input logic[31:0] data);
    // AW
    @(posedge clk);
    force u_soc.u_dma.dma_s_awvalid = 1'b1;
    force u_soc.u_dma.dma_s_awaddr = addr;
    @(posedge clk);
    wait(u_soc.u_dma.dma_s_awready);
    force u_soc.u_dma.dma_s_awvalid = 1'b0;
    // W
    force u_soc.u_dma.dma_s_wvalid = 1'b1;
    force u_soc.u_dma.dma_s_wdata = data;
    force u_soc.u_dma.dma_s_wstrb = 4'hF;
    force u_soc.u_dma.dma_s_wlast = 1'b1;
    @(posedge clk);
    wait(u_soc.u_dma.dma_s_wready);
    force u_soc.u_dma.dma_s_wvalid = 1'b0;
    force u_soc.u_dma.dma_s_wlast = 1'b0;
    // B
    force u_soc.u_dma.dma_s_bready = 1'b1;
    @(posedge clk);
    wait(u_soc.u_dma.dma_s_bvalid);
    @(posedge clk);
    force u_soc.u_dma.dma_s_bready = 1'b0;
  endtask

  // 等待 DMA
  task wait_dma(input int ns);
    fork
      begin wait(dma_done||dma_error||cpu_trap); end
      begin #ns; $error("[TB] TIMEOUT %0dns",ns); $stop; end
    join_any disable fork;
  endtask

  // 测试统计
  int pass_cnt=0, fail_cnt=0;
  task check(string name, bit ok);
    if(ok) begin $display("[TB] PASS: %s",name); pass_cnt++; end
    else    begin $error("[TB] FAIL: %s",name);  fail_cnt++; end
  endtask

  // ============================================================
  // Test 1: DMA DDR → NPU LMEM
  // ============================================================
  task test_dma();
    localparam int N = 4088;
    bit mismatch;
    $display("\n[TB] === Test 1: DMA DDR → NPU LMEM ===");
    wait(!rst); @(posedge clk);
    for(int i=0;i<N;i++) begin `DDR_MEM[i]=8'h10+i[7:0]; `NPU_MEM[i]=0; end
    repeat(10) @(posedge clk);
    wait_dma(2_000_000);
    mismatch = 0;
    for(int i=0;i<N;i++) if(`DDR_MEM[i]!==`NPU_MEM[i]) mismatch=1;
    if(cpu_trap)        check("DMA",0);
    else if(dma_error)  check("DMA",0);
    else if(!dma_done)  check("DMA",0);
    else if(mismatch)   check("DMA",0);
    else                check("DMA",1);
  endtask

  // ============================================================
  // Test 2: NPU CSR 寄存器读写
  // ============================================================
  task test_npu_csr();
    logic[31:0] r; bit ok;
    $display("\n[TB] === Test 2: NPU CSR R/W ===");
    repeat(20) @(posedge clk); ok=1;
    npu_csr_write(8'h08, 32'hDEAD_BEEF);
    npu_csr_write(8'h0C, 32'hCAFE_1234);
    npu_csr_write(8'h10, 32'h0000_1000);
    npu_csr_write(8'h14, 32'h0000_0001);
    r = u_soc.u_csr_npu.reg_src;  if(r!==32'hDEAD_BEEF) begin $display("[TB] SRC=%08x",r); ok=0; end
    r = u_soc.u_csr_npu.reg_dst;  if(r!==32'hCAFE_1234) begin $display("[TB] DST=%08x",r); ok=0; end
    r = u_soc.u_csr_npu.reg_len;  if(r!==32'h0000_1000) begin $display("[TB] LEN=%08x",r); ok=0; end
    r = u_soc.u_csr_npu.reg_cfg;  if(r!==32'h0000_0001) begin $display("[TB] CFG=%08x",r); ok=0; end
    npu_csr_write(8'h00, 32'h0000_0001); // start
    repeat(10) @(posedge clk);
    npu_csr_write(8'h04, 32'h0000_0002); // clear done
    npu_csr_write(8'h00, 32'h0000_0002); // irq_en
    check("NPU CSR", ok);
  endtask

  // ============================================================
  // Test 3: DDR 直接读写
  // ============================================================
  task test_ddr_rw();
    logic[31:0] r; bit ok;
    $display("\n[TB] === Test 3: DDR R/W ===");
    repeat(20) @(posedge clk); ok=1;
    ddr_write32(DDR_BASE+0, 32'hA5A5_5A5A);
    ddr_write32(DDR_BASE+4, 32'hFFFF_0000);
    ddr_write32(DDR_BASE+8, 32'h1234_5678);
    ddr_write32(DDR_BASE+32'h03FF_FFFC, 32'hCAFE_BABE);
    ddr_read32(DDR_BASE+0, r);  if(r!==32'hA5A5_5A5A) begin ok=0; end
    ddr_read32(DDR_BASE+4, r);  if(r!==32'hFFFF_0000) begin ok=0; end
    ddr_read32(DDR_BASE+8, r);  if(r!==32'h1234_5678) begin ok=0; end
    ddr_read32(DDR_BASE+32'h03FF_FFFC, r); if(r!==32'hCAFE_BABE) begin ok=0; end
    check("DDR R/W", ok);
  endtask

  // ============================================================
  // Test 4: NPU LMEM 直接读写
  // ============================================================
  task test_npu_rw();
    logic[31:0] r; bit ok;
    $display("\n[TB] === Test 4: NPU LMEM R/W ===");
    repeat(20) @(posedge clk); ok=1;
    npu_write32(NPU_LMEM_BASE+0, 32'h1111_2222);
    npu_write32(NPU_LMEM_BASE+4, 32'h3333_4444);
    npu_write32(NPU_LMEM_BASE+32'h1000, 32'hAAAA_BBBB);
    npu_read32(NPU_LMEM_BASE+0, r);       if(r!==32'h1111_2222) begin ok=0; end
    npu_read32(NPU_LMEM_BASE+4, r);       if(r!==32'h3333_4444) begin ok=0; end
    npu_read32(NPU_LMEM_BASE+32'h1000, r); if(r!==32'hAAAA_BBBB) begin ok=0; end
    check("NPU LMEM", ok);
  endtask

  // ============================================================
  // Test 5: DDR FSM 覆盖
  // ============================================================
  task test_ddr_fsm();
    logic[31:0] r; bit ok;
    $display("\n[TB] === Test 5: DDR FSM ===");
    repeat(20) @(posedge clk); ok=1;
    for(int i=0;i<64;i++) ddr_write32(DDR_BASE+i*4, 32'h1000_0000+i);
    for(int i=0;i<64;i++) begin
      ddr_read32(DDR_BASE+i*4, r);
      if(r!==(32'h1000_0000+i)) ok=0;
    end
    ddr_write32(DDR_BASE+32'h03FF_FFF0, 32'hCAFE_BABE);
    ddr_read32(DDR_BASE+32'h03FF_FFF0, r);
    if(r!==32'hCAFE_BABE) ok=0;
    check("DDR FSM", ok);
  endtask

  // ============================================================
  // Test 6: NPU CSR 全寄存器覆盖
  // ============================================================
  task test_npu_csr_full();
    logic[31:0] r; bit ok;
    $display("\n[TB] === Test 6: NPU CSR Full ===");
    repeat(20) @(posedge clk); ok=1;
    npu_csr_write(8'h08, 32'h1111_1111);
    npu_csr_write(8'h0C, 32'h2222_2222);
    npu_csr_write(8'h10, 32'h3333_3333);
    npu_csr_write(8'h14, 32'h4444_4444);
    npu_csr_write(8'h00, 32'h0000_0001);
    repeat(10) @(posedge clk);
    r = u_soc.u_csr_npu.reg_src;  if(r!==32'h1111_1111) ok=0;
    r = u_soc.u_csr_npu.reg_dst;  if(r!==32'h2222_2222) ok=0;
    r = u_soc.u_csr_npu.reg_len;  if(r!==32'h3333_3333) ok=0;
    r = u_soc.u_csr_npu.reg_cfg;  if(r!==32'h4444_4444) ok=0;
    npu_csr_write(8'h04, 32'hFFFFFFFF);
    npu_csr_write(8'h00, 32'h0000_0002);
    check("NPU CSR Full", ok);
  endtask

  // ============================================================
  // Test 7: DMA 反向传输 (NPU → DDR)
  // ============================================================
  task test_dma_reverse();
    localparam int N=256;
    bit mismatch;
    $display("\n[TB] === Test 7: DMA NPU→DDR ===");
    repeat(50) @(posedge clk);
    for(int i=0;i<N;i++) begin `NPU_MEM[i]=8'hA0+i[7:0]; `DDR_MEM[i]=0; end
    // 初始化 DMA AXI-Lite 端口
    force u_soc.u_dma.dma_s_awvalid=0; force u_soc.u_dma.dma_s_wvalid=0;
    force u_soc.u_dma.dma_s_bready=0; force u_soc.u_dma.dma_s_arvalid=0;
    force u_soc.u_dma.dma_s_rready=0; force u_soc.u_dma.dma_s_awprot=0;
    force u_soc.u_dma.dma_s_arprot=0;
    repeat(5) @(posedge clk);
    // 配置 DMA CSR
    dma_axil_write(32'h20, NPU_LMEM_BASE);  // SRC
    dma_axil_write(32'h30, DDR_BASE);        // DST
    dma_axil_write(32'h40, N);               // NUM
    dma_axil_write(32'h50, 32'h1);           // CFG
    dma_axil_write(32'h00, 32'h3FD);         // GO
    wait_dma(500_000);
    mismatch=0;
    for(int i=0;i<N;i++) if(`NPU_MEM[i]!==`DDR_MEM[i]) mismatch=1;
    if(dma_error||!dma_done||mismatch) check("DMA reverse",0);
    else                               check("DMA reverse",1);
  endtask

  // ============================================================
  // Test 8: DMA 小数据量 (16 bytes)
  // ============================================================
  task test_dma_small();
    localparam int N=16;
    bit mismatch;
    $display("\n[TB] === Test 8: DMA Small (16B) ===");
    repeat(50) @(posedge clk);
    for(int i=0;i<N;i++) begin `DDR_MEM[64+i]=8'hF0+i[3:0]; `NPU_MEM[64+i]=0; end
    dma_axil_write(32'h20, DDR_BASE+64);
    dma_axil_write(32'h30, NPU_LMEM_BASE+64);
    dma_axil_write(32'h40, N);
    dma_axil_write(32'h50, 32'h1);
    dma_axil_write(32'h00, 32'h3FD);
    wait_dma(500_000);
    mismatch=0;
    for(int i=0;i<N;i++) if(`DDR_MEM[64+i]!==`NPU_MEM[64+i]) mismatch=1;
    if(dma_error||!dma_done||mismatch) check("DMA small",0);
    else                               check("DMA small",1);
  endtask

  // ============================================================
  // 主流程
  // ============================================================
  initial begin
    $display("\n[TB] ==============================");
    $display("[TB] SoC Testbench Start");
    $display("[TB] ==============================");

    test_dma();
    test_npu_csr();
    test_ddr_rw();
    test_npu_rw();
    test_ddr_fsm();
    test_npu_csr_full();
    test_dma_reverse();
    test_dma_small();

    $display("\n[TB] ==============================");
    $display("[TB] Summary: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
    $display("[TB] ==============================");
    if(fail_cnt>0) $error("[TB] %0d TESTS FAILED", fail_cnt);
    else           $display("[TB] ALL TESTS PASSED");
    $stop;
  end

  // 超时
  initial begin #10ms; $error("[TB] GLOBAL TIMEOUT"); $stop; end

endmodule
`default_nettype wire
