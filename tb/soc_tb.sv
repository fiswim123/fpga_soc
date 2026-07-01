`timescale 1ns/1ps
`default_nettype none

module soc_tb;

  localparam logic [31:0] DDR_BASE      = 32'h4000_0000;
  localparam logic [31:0] NPU_LMEM_BASE = 32'h0000_1000;
  localparam logic [31:0] NPU_CSR_BASE  = 32'h0003_0000;
  localparam logic [31:0] DMA_CSR_BASE  = 32'h0002_1000;

  logic clk, rst;
  initial begin clk=0; forever #2.5 clk=~clk; end
  initial begin rst=1; #100 rst=0; end

  logic dma_done, dma_error, cpu_trap;
  soc_top #(.DDR_INIT_FILE("")) u_soc (
    .clk(clk), .rst(rst),
    .dma_done_o(dma_done), .dma_error_o(dma_error), .cpu_trap_o(cpu_trap)
  );

  `define DDR_MEM u_soc.u_ddr.mem
  `define NPU_MEM u_soc.u_npu.u_npu_ram.mem

  // ================================================================
  // 辅助 task
  // ================================================================
  task ddr_write32(input logic[31:0] addr, input logic[31:0] data);
    int b; b = addr - DDR_BASE;
    `DDR_MEM[b+3]=data[31:24]; `DDR_MEM[b+2]=data[23:16]; `DDR_MEM[b+1]=data[15:8]; `DDR_MEM[b+0]=data[7:0];
  endtask
  task ddr_read32(input logic[31:0] addr, output logic[31:0] data);
    int b; b = addr - DDR_BASE;
    data = {`DDR_MEM[b+3],`DDR_MEM[b+2],`DDR_MEM[b+1],`DDR_MEM[b+0]};
  endtask

  int pass_cnt=0, fail_cnt=0;
  task check(string name, bit ok);
    if(ok) begin $display("[TB] PASS: %s",name); pass_cnt++; end
    else    begin $error("[TB] FAIL: %s",name);  fail_cnt++; end
  endtask

  // ================================================================
  // Test: CPU-driven DMA → NPU inference (end-to-end)
  // CPU fetches instr_data.dat from ROM, configures DMA via CSR bus,
  // DMA copies DDR image to NPU LMEM, CPU triggers NPU, polls pred_valid.
  // Result is left in CPU registers (s2=class_id, s3=logit) and
  // readable via NPU CSR PRED register.
  // ================================================================
  task test_cpu_dma_npu();
    $display("\n[TB] === CPU-driven DMA + NPU Inference ===");
    begin
      int fd;
      logic [23:0] pixel;
      logic [31:0] ddr_word;
      int addr;
      int timeout;
      bit ok;
      int start_time, end_time, elapsed_cycles;

      // 1. Pre-fill DDR with image_data.dat (same format as test_npu_conv1)
      fd = $fopen("../src/npu/image_data.dat", "r");
      if (fd == 0) begin
        $error("[TB] Cannot open image_data.dat");
        check("CPU DMA+NPU", 0);
        return;
      end
      addr = 0;
      for (int i = 0; i < 1024; i++) begin
        $fscanf(fd, "%h", pixel);
        ddr_word = {8'h00, pixel};
        `DDR_MEM[addr+3] = ddr_word[31:24];
        `DDR_MEM[addr+2] = ddr_word[23:16];
        `DDR_MEM[addr+1] = ddr_word[15:8];
        `DDR_MEM[addr+0] = ddr_word[7:0];
        addr += 4;
      end
      $fclose(fd);
      $display("[TB]   DDR pre-loaded with 1024 pixels (4096 bytes)");

      // 2. Reset CPU so it starts fetching from ROM
      rst = 1'b1;
      repeat(20) @(posedge clk);
      rst = 1'b0;
      start_time = $time;
      $display("[TB]   CPU released from reset, executing ROM...");

      // 3. Wait for NPU pred_valid (CPU triggers full pipeline via CSR write to CTRL[0])
      //    The CPU writes 0x01 to NPU CSR 0x00030000, which triggers:
      //    img_load → conv → FC → pred_valid
      timeout = 0;
      ok = 0;
      while (timeout < 80_000_000) begin
        @(posedge clk);
        timeout++;
        if (u_soc.u_npu.pred_valid) begin
          ok = 1;
          break;
        end
      end

      end_time = $time;
      elapsed_cycles = (end_time - start_time) / 5;

      if (!ok) begin
        $error("[TB] CPU DMA+NPU TIMEOUT: pred_valid not asserted (%0d ns)", timeout * 5);
        check("CPU DMA+NPU", 0);
        return;
      end

      repeat(5) @(posedge clk);

      // 4. Read result from NPU output ports (directly from npu_top)
      begin
        logic [3:0]  class_id;
        logic [7:0]  logit;
        class_id = u_soc.u_npu.pred_class_id;
        logit    = u_soc.u_npu.pred_logit;
        $display("[TB]   pred_valid  = %0b", u_soc.u_npu.pred_valid);
        $display("[TB]   class_id    = %0d", class_id);
        $display("[TB]   logit       = %0d", $signed(logit));
        $display("[TB]   completed in %0d cycles (%0d ns)", elapsed_cycles, elapsed_cycles * 5);

        // 5. Verify pred_valid
        ok = u_soc.u_npu.pred_valid;
        if (!ok) $display("[TB]   pred_valid deasserted unexpectedly");

        // 6. Verify DMA transferred data: check first 64 bytes of NPU RAM vs DDR
        if (ok) begin
          for (int i = 0; i < 64; i++) begin
            if (`NPU_MEM[i] !== `DDR_MEM[i]) begin
              $display("[TB]   DMA MISMATCH at byte %0d: NPU=0x%02h DDR=0x%02h",
                       i, `NPU_MEM[i], `DDR_MEM[i]);
              ok = 0;
              break;
            end
          end
          if (ok) $display("[TB]   DMA data verified: NPU RAM[0..63] matches DDR");
        end

        // 7. Performance summary
        $display("[TB]   ----------------------------------------");
        $display("[TB]   End-to-End Performance Summary:");
        $display("[TB]     Total Cycles    : %0d", elapsed_cycles);
        $display("[TB]     Total Time      : %0d ns", elapsed_cycles * 5);
        $display("[TB]     Clock Frequency : 200 MHz");
        $display("[TB]     DMA Transfer    : 4096 bytes (DDR → NPU LMEM)");
        $display("[TB]     NPU Inference   : Conv1 + Conv2 + FC");
        $display("[TB]   ----------------------------------------");

        check("CPU DMA+NPU", ok);
      end
    end
  endtask

  // ================================================================
  // 主流程
  // ================================================================
  initial begin
    $display("\n[TB] ==============================");
    $display("[TB] CPU-driven DMA + NPU Inference");
    $display("[TB] ==============================");

    test_cpu_dma_npu();

    $display("\n[TB] ==============================");
    $display("[TB] Summary: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
    $display("[TB] ==============================");
    if(fail_cnt>0) $error("[TB] %0d TESTS FAILED", fail_cnt);
    else           $display("[TB] ALL TESTS PASSED");
    $stop;
  end

  initial begin #200ms; $error("[TB] GLOBAL TIMEOUT"); $stop; end

endmodule
`default_nettype wire
