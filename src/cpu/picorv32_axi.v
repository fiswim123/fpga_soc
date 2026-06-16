`timescale 1 ns / 1 ps

/***************************************************************
 * picorv32_axi
 ***************************************************************/

module picorv32_axi #(
	parameter [ 0:0] ENABLE_COUNTERS = 1,
	parameter [ 0:0] ENABLE_COUNTERS64 = 1,
	parameter [ 0:0] ENABLE_REGS_16_31 = 1,
	parameter [ 0:0] ENABLE_REGS_DUALPORT = 1,
	parameter [ 0:0] TWO_STAGE_SHIFT = 1,
	parameter [ 0:0] BARREL_SHIFTER = 0,
	parameter [ 0:0] TWO_CYCLE_COMPARE = 0,
	parameter [ 0:0] TWO_CYCLE_ALU = 0,
	parameter [ 0:0] COMPRESSED_ISA = 0,
	parameter [ 0:0] CATCH_MISALIGN = 1,
	parameter [ 0:0] CATCH_ILLINSN = 1,
	parameter [ 0:0] ENABLE_PCPI = 0,
	parameter [ 0:0] ENABLE_MUL = 0,
	parameter [ 0:0] ENABLE_FAST_MUL = 0,
	parameter [ 0:0] ENABLE_DIV = 0,
	parameter [ 0:0] ENABLE_IRQ = 0,
	parameter [ 0:0] ENABLE_IRQ_QREGS = 1,
	parameter [ 0:0] ENABLE_IRQ_TIMER = 1,
	parameter [ 0:0] ENABLE_TRACE = 0,
	parameter [ 0:0] REGS_INIT_ZERO = 0,
	parameter [31:0] MASKED_IRQ = 32'h 0000_0000,
	parameter [31:0] LATCHED_IRQ = 32'h ffff_ffff,
	parameter [31:0] PROGADDR_RESET = 32'h 0000_0000,
	parameter [31:0] PROGADDR_IRQ = 32'h 0000_0010,
	parameter [31:0] STACKADDR = 32'h ffff_ffff,
	parameter [31:0] LOCAL_ROM_BASE = 32'h 0000_0000,
	parameter integer LOCAL_ROM_ADDR_WIDTH = 12,
	parameter [31:0] LOCAL_RAM_BASE = 32'h 1000_0000,
	parameter integer LOCAL_RAM_ADDR_WIDTH = 12,
	parameter [8*128-1:0] LOCAL_ROM_INIT_FILE = ""
) (
	input clk, resetn,
	output trap,

	// AXI4-lite master memory interface

	output        mem_axi_awvalid,
	input         mem_axi_awready,
	output [31:0] mem_axi_awaddr,
	output [ 2:0] mem_axi_awprot,

	output        mem_axi_wvalid,
	input         mem_axi_wready,
	output [31:0] mem_axi_wdata,
	output [ 3:0] mem_axi_wstrb,

	input         mem_axi_bvalid,
	output        mem_axi_bready,

	output        mem_axi_arvalid,
	input         mem_axi_arready,
	output [31:0] mem_axi_araddr,
	output [ 2:0] mem_axi_arprot,

	input         mem_axi_rvalid,
	output        mem_axi_rready,
	input  [31:0] mem_axi_rdata,

	// Pico Co-Processor Interface (PCPI)
	output        pcpi_valid,
	output [31:0] pcpi_insn,
	output [31:0] pcpi_rs1,
	output [31:0] pcpi_rs2,
	input         pcpi_wr,
	input  [31:0] pcpi_rd,
	input         pcpi_wait,
	input         pcpi_ready,

	// IRQ interface
	input  [31:0] irq,
	output [31:0] eoi,

`ifdef RISCV_FORMAL
	output        rvfi_valid,
	output [63:0] rvfi_order,
	output [31:0] rvfi_insn,
	output        rvfi_trap,
	output        rvfi_halt,
	output        rvfi_intr,
	output [ 4:0] rvfi_rs1_addr,
	output [ 4:0] rvfi_rs2_addr,
	output [31:0] rvfi_rs1_rdata,
	output [31:0] rvfi_rs2_rdata,
	output [ 4:0] rvfi_rd_addr,
	output [31:0] rvfi_rd_wdata,
	output [31:0] rvfi_pc_rdata,
	output [31:0] rvfi_pc_wdata,
	output [31:0] rvfi_mem_addr,
	output [ 3:0] rvfi_mem_rmask,
	output [ 3:0] rvfi_mem_wmask,
	output [31:0] rvfi_mem_rdata,
	output [31:0] rvfi_mem_wdata,
`endif

	// Trace Interface
	output        trace_valid,
	output [35:0] trace_data
);
	wire        core_mem_valid;
	wire [31:0] core_mem_addr;
	wire [31:0] core_mem_wdata;
	wire [ 3:0] core_mem_wstrb;
	wire        core_mem_instr;
	wire        core_mem_ready;
	wire [31:0] core_mem_rdata;
	wire        core_mem_la_read_unused;
	wire        core_mem_la_write_unused;
	wire [31:0] core_mem_la_addr_unused;
	wire [31:0] core_mem_la_wdata_unused;
	wire [ 3:0] core_mem_la_wstrb_unused;

	wire        axi_mem_valid;
	wire [31:0] axi_mem_addr;
	wire [31:0] axi_mem_wdata;
	wire [ 3:0] axi_mem_wstrb;
	wire        axi_mem_instr;
	wire        axi_mem_ready;
	wire [31:0] axi_mem_rdata;

	picorv32_mem_router #(
		.LOCAL_ROM_BASE      (LOCAL_ROM_BASE      ),
		.LOCAL_ROM_ADDR_WIDTH(LOCAL_ROM_ADDR_WIDTH),
		.LOCAL_RAM_BASE      (LOCAL_RAM_BASE      ),
		.LOCAL_RAM_ADDR_WIDTH(LOCAL_RAM_ADDR_WIDTH),
		.LOCAL_ROM_INIT_FILE (LOCAL_ROM_INIT_FILE )
	) mem_router (
		.clk         (clk          ),
		.resetn      (resetn       ),
		.mem_valid   (core_mem_valid),
		.mem_instr   (core_mem_instr),
		.mem_ready   (core_mem_ready),
		.mem_addr    (core_mem_addr ),
		.mem_wdata   (core_mem_wdata),
		.mem_wstrb   (core_mem_wstrb),
		.mem_rdata   (core_mem_rdata),
		.axi_mem_valid(axi_mem_valid),
		.axi_mem_instr(axi_mem_instr),
		.axi_mem_ready(axi_mem_ready),
		.axi_mem_addr (axi_mem_addr ),
		.axi_mem_wdata(axi_mem_wdata),
		.axi_mem_wstrb(axi_mem_wstrb),
		.axi_mem_rdata(axi_mem_rdata)
	);

	picorv32_axi_adapter axi_adapter (
		.clk            (clk            ),
		.resetn         (resetn         ),
		.mem_axi_awvalid(mem_axi_awvalid),
		.mem_axi_awready(mem_axi_awready),
		.mem_axi_awaddr (mem_axi_awaddr ),
		.mem_axi_awprot (mem_axi_awprot ),
		.mem_axi_wvalid (mem_axi_wvalid ),
		.mem_axi_wready (mem_axi_wready ),
		.mem_axi_wdata  (mem_axi_wdata  ),
		.mem_axi_wstrb  (mem_axi_wstrb  ),
		.mem_axi_bvalid (mem_axi_bvalid ),
		.mem_axi_bready (mem_axi_bready ),
		.mem_axi_arvalid(mem_axi_arvalid),
		.mem_axi_arready(mem_axi_arready),
		.mem_axi_araddr (mem_axi_araddr ),
		.mem_axi_arprot (mem_axi_arprot ),
		.mem_axi_rvalid (mem_axi_rvalid ),
		.mem_axi_rready (mem_axi_rready ),
		.mem_axi_rdata  (mem_axi_rdata  ),
		.mem_valid      (axi_mem_valid  ),
		.mem_instr      (axi_mem_instr  ),
		.mem_ready      (axi_mem_ready  ),
		.mem_addr       (axi_mem_addr   ),
		.mem_wdata      (axi_mem_wdata  ),
		.mem_wstrb      (axi_mem_wstrb  ),
		.mem_rdata      (axi_mem_rdata  )
	);

	picorv32 #(
		.ENABLE_COUNTERS     (ENABLE_COUNTERS     ),
		.ENABLE_COUNTERS64   (ENABLE_COUNTERS64   ),
		.ENABLE_REGS_16_31   (ENABLE_REGS_16_31   ),
		.ENABLE_REGS_DUALPORT(ENABLE_REGS_DUALPORT),
		.TWO_STAGE_SHIFT     (TWO_STAGE_SHIFT     ),
		.BARREL_SHIFTER      (BARREL_SHIFTER      ),
		.TWO_CYCLE_COMPARE   (TWO_CYCLE_COMPARE   ),
		.TWO_CYCLE_ALU       (TWO_CYCLE_ALU       ),
		.COMPRESSED_ISA      (COMPRESSED_ISA      ),
		.CATCH_MISALIGN      (CATCH_MISALIGN      ),
		.CATCH_ILLINSN       (CATCH_ILLINSN       ),
		.ENABLE_PCPI         (ENABLE_PCPI         ),
		.ENABLE_MUL          (ENABLE_MUL          ),
		.ENABLE_FAST_MUL     (ENABLE_FAST_MUL     ),
		.ENABLE_DIV          (ENABLE_DIV          ),
		.ENABLE_IRQ          (ENABLE_IRQ          ),
		.ENABLE_IRQ_QREGS    (ENABLE_IRQ_QREGS    ),
		.ENABLE_IRQ_TIMER    (ENABLE_IRQ_TIMER    ),
		.ENABLE_TRACE        (ENABLE_TRACE        ),
		.REGS_INIT_ZERO      (REGS_INIT_ZERO      ),
		.MASKED_IRQ          (MASKED_IRQ          ),
		.LATCHED_IRQ         (LATCHED_IRQ         ),
		.PROGADDR_RESET      (PROGADDR_RESET      ),
		.PROGADDR_IRQ        (PROGADDR_IRQ        ),
		.STACKADDR           (STACKADDR           )
	) picorv32_core (
		.clk      (clk   ),
		.resetn   (resetn),
		.trap     (trap  ),

		.mem_valid(core_mem_valid),
		.mem_addr (core_mem_addr ),
		.mem_wdata(core_mem_wdata),
		.mem_wstrb(core_mem_wstrb),
		.mem_instr(core_mem_instr),
		.mem_ready(core_mem_ready),
		.mem_rdata(core_mem_rdata),
		.mem_la_read (core_mem_la_read_unused ),
		.mem_la_write(core_mem_la_write_unused),
		.mem_la_addr (core_mem_la_addr_unused ),
		.mem_la_wdata(core_mem_la_wdata_unused),
		.mem_la_wstrb(core_mem_la_wstrb_unused),

		.pcpi_valid(pcpi_valid),
		.pcpi_insn (pcpi_insn ),
		.pcpi_rs1  (pcpi_rs1  ),
		.pcpi_rs2  (pcpi_rs2  ),
		.pcpi_wr   (pcpi_wr   ),
		.pcpi_rd   (pcpi_rd   ),
		.pcpi_wait (pcpi_wait ),
		.pcpi_ready(pcpi_ready),

		.irq(irq),
		.eoi(eoi),

`ifdef RISCV_FORMAL
		.rvfi_valid    (rvfi_valid    ),
		.rvfi_order    (rvfi_order    ),
		.rvfi_insn     (rvfi_insn     ),
		.rvfi_trap     (rvfi_trap     ),
		.rvfi_halt     (rvfi_halt     ),
		.rvfi_intr     (rvfi_intr     ),
		.rvfi_rs1_addr (rvfi_rs1_addr ),
		.rvfi_rs2_addr (rvfi_rs2_addr ),
		.rvfi_rs1_rdata(rvfi_rs1_rdata),
		.rvfi_rs2_rdata(rvfi_rs2_rdata),
		.rvfi_rd_addr  (rvfi_rd_addr  ),
		.rvfi_rd_wdata (rvfi_rd_wdata ),
		.rvfi_pc_rdata (rvfi_pc_rdata ),
		.rvfi_pc_wdata (rvfi_pc_wdata ),
		.rvfi_mem_addr (rvfi_mem_addr ),
		.rvfi_mem_rmask(rvfi_mem_rmask),
		.rvfi_mem_wmask(rvfi_mem_wmask),
		.rvfi_mem_rdata(rvfi_mem_rdata),
		.rvfi_mem_wdata(rvfi_mem_wdata),
`endif

		.trace_valid(trace_valid),
		.trace_data (trace_data)
	);
endmodule


/***************************************************************
 * picorv32_mem_router
 ***************************************************************/

module picorv32_mem_router #(
	parameter [31:0] LOCAL_ROM_BASE = 32'h 0000_0000,
	parameter integer LOCAL_ROM_ADDR_WIDTH = 12,
	parameter [31:0] LOCAL_RAM_BASE = 32'h 1000_0000,
	parameter integer LOCAL_RAM_ADDR_WIDTH = 12,
	parameter [8*128-1:0] LOCAL_ROM_INIT_FILE = ""
) (
	input clk,
	input resetn,

	input         mem_valid,
	input         mem_instr,
	output        mem_ready,
	input  [31:0] mem_addr,
	input  [31:0] mem_wdata,
	input  [ 3:0] mem_wstrb,
	output [31:0] mem_rdata,

	output        axi_mem_valid,
	output        axi_mem_instr,
	input         axi_mem_ready,
	output [31:0] axi_mem_addr,
	output [31:0] axi_mem_wdata,
	output [ 3:0] axi_mem_wstrb,
	input  [31:0] axi_mem_rdata
);
	wire in_rom_region;
	wire in_ram_region;
	wire use_local_rom;
	wire use_local_ram;
	wire use_local;

	wire [31:0] local_rom_rdata;
	wire [31:0] local_ram_rdata;

	assign in_rom_region = mem_addr[31:LOCAL_ROM_ADDR_WIDTH+2] == LOCAL_ROM_BASE[31:LOCAL_ROM_ADDR_WIDTH+2];
	assign in_ram_region = mem_addr[31:LOCAL_RAM_ADDR_WIDTH+2] == LOCAL_RAM_BASE[31:LOCAL_RAM_ADDR_WIDTH+2];

	assign use_local_rom = mem_valid && mem_instr && (mem_wstrb == 4'b0000) && in_rom_region;
	assign use_local_ram = mem_valid && !mem_instr && in_ram_region;
	assign use_local = use_local_rom || use_local_ram;

	assign mem_ready = use_local ? 1'b1 : axi_mem_ready;
	assign mem_rdata = use_local_rom ? local_rom_rdata :
				   (use_local_ram ? local_ram_rdata : axi_mem_rdata);

	assign axi_mem_valid = mem_valid && !use_local;
	assign axi_mem_instr = mem_instr;
	assign axi_mem_addr = mem_addr;
	assign axi_mem_wdata = mem_wdata;
	assign axi_mem_wstrb = mem_wstrb;

	/*
always @(posedge clk) begin
  if (mem_valid) begin
    $display("[ROUTER] t=%0t addr=%08x instr=%0b wstrb=%0h inROM=%0b inRAM=%0b useROM=%0b useRAM=%0b use_local=%0b axi_valid=%0b ready=%0b",
      $time, mem_addr, mem_instr, mem_wstrb,
      in_rom_region, in_ram_region, use_local_rom, use_local_ram, use_local, axi_mem_valid, mem_ready);
  end
end
*/
	picorv32_local_rom #(
		.ADDR_WIDTH(LOCAL_ROM_ADDR_WIDTH),
		.INIT_FILE (LOCAL_ROM_INIT_FILE )
	) local_rom (
		.addr (mem_addr       ),
		.rdata(local_rom_rdata)
	);

	picorv32_local_ram #(
		.ADDR_WIDTH(LOCAL_RAM_ADDR_WIDTH)
	) local_ram (
		.clk  (clk                                ),
		.resetn(resetn                             ),
		.wen  (use_local_ram && (mem_wstrb != 4'b0)),
		.addr (mem_addr                           ),
		.wdata(mem_wdata                          ),
		.wstrb(mem_wstrb                          ),
		.rdata(local_ram_rdata                    )
	);
endmodule


/***************************************************************
 * picorv32_local_rom
 ***************************************************************/

module picorv32_local_rom #(
	parameter integer ADDR_WIDTH = 12,
	parameter  INIT_FILE = "instr_data.dat"
) (
	input  [31:0] addr,
	output [31:0] rdata
);
	localparam integer DEPTH = (1 << ADDR_WIDTH);

	reg [31:0] mem [0:DEPTH-1];
	integer i,k;

	initial begin
		for (i = 0; i < DEPTH; i = i + 1)
			mem[i] = 32'h00000013;
		if (INIT_FILE != 0)
			$readmemh(INIT_FILE, mem);
	end
	initial begin
  		#1;
  		for (k=0; k<8; k=k+1) begin
   			$display("[ROM] mem[%0d]=0x%08x", k, mem[k]);
 	 	end
	end
	assign rdata = mem[addr[ADDR_WIDTH+1:2]];
endmodule


/***************************************************************
 * picorv32_local_ram
 ***************************************************************/

module picorv32_local_ram #(
	parameter integer ADDR_WIDTH = 12
) (
	input clk,
	input resetn,
	input wen,
	input [31:0] addr,
	input [31:0] wdata,
	input [ 3:0] wstrb,
	output [31:0] rdata
);
	localparam integer DEPTH = (1 << ADDR_WIDTH);

	reg [31:0] mem [0:DEPTH-1];
	wire [ADDR_WIDTH-1:0] word_addr;
	integer i;

	assign word_addr = addr[ADDR_WIDTH+1:2];
	assign rdata = mem[word_addr];

	always @(posedge clk) begin
		if (!resetn) begin
			for (i = 0; i < DEPTH; i = i + 1)
				mem[i] <= 0;
		end else if (wen) begin
			if (wstrb[0]) mem[word_addr][ 7: 0] <= wdata[ 7: 0];
			if (wstrb[1]) mem[word_addr][15: 8] <= wdata[15: 8];
			if (wstrb[2]) mem[word_addr][23:16] <= wdata[23:16];
			if (wstrb[3]) mem[word_addr][31:24] <= wdata[31:24];
		end
	end
endmodule


/***************************************************************
 * picorv32_axi_adapter (patched: robust ready/response handling)
 ***************************************************************/

module picorv32_axi_adapter (
	input clk, resetn,

	// AXI4-lite master memory interface
	output        mem_axi_awvalid,
	input         mem_axi_awready,
	output [31:0] mem_axi_awaddr,
	output [ 2:0] mem_axi_awprot,

	output        mem_axi_wvalid,
	input         mem_axi_wready,
	output [31:0] mem_axi_wdata,
	output [ 3:0] mem_axi_wstrb,

	input         mem_axi_bvalid,
	output        mem_axi_bready,

	output        mem_axi_arvalid,
	input         mem_axi_arready,
	output [31:0] mem_axi_araddr,
	output [ 2:0] mem_axi_arprot,

	input         mem_axi_rvalid,
	output        mem_axi_rready,
	input  [31:0] mem_axi_rdata,

	// Native PicoRV32 memory interface
	input         mem_valid,
	input         mem_instr,
	output        mem_ready,
	input  [31:0] mem_addr,
	input  [31:0] mem_wdata,
	input  [ 3:0] mem_wstrb,
	output [31:0] mem_rdata
);

/*
always @(posedge clk) if (mem_valid)
  $display("[ADP] t=%0t v=%0b wstrb=%h awv/r=%0b/%0b wv/r=%0b/%0b bv/r=%0b/%0b pwr=%0b ready=%0b",
    $time, mem_valid, mem_wstrb,
    mem_axi_awvalid, mem_axi_awready,
    mem_axi_wvalid,  mem_axi_wready,
    mem_axi_bvalid,  mem_axi_bready,
    pending_wr_rsp, mem_ready);*/

	reg ack_awvalid, ack_wvalid, ack_arvalid;
	reg pending_wr_rsp, pending_rd_rsp;

	wire is_write = mem_valid && (|mem_wstrb);
	wire is_read  = mem_valid && !(|mem_wstrb);

	// request channels
	assign mem_axi_awvalid = is_write && !ack_awvalid;
	assign mem_axi_awaddr  = mem_addr;
	assign mem_axi_awprot  = 3'b000;

	assign mem_axi_wvalid  = is_write && !ack_wvalid;
	assign mem_axi_wdata   = mem_wdata;
	assign mem_axi_wstrb   = mem_wstrb;

	assign mem_axi_arvalid = is_read  && !ack_arvalid;
	assign mem_axi_araddr  = mem_addr;
	assign mem_axi_arprot  = mem_instr ? 3'b100 : 3'b000;

	// IMPORTANT: keep ready high during pending response (avoid missing pulse)
	assign mem_axi_bready = pending_wr_rsp;
	assign mem_axi_rready = pending_rd_rsp;

	// Only declare mem_ready when waiting for that response type
	assign mem_ready = (pending_wr_rsp && mem_axi_bvalid) ||
	                   (pending_rd_rsp && mem_axi_rvalid);

	assign mem_rdata = mem_axi_rdata;

	always @(posedge clk) begin
		if (!resetn) begin
			ack_awvalid    <= 1'b0;
			ack_wvalid     <= 1'b0;
			ack_arvalid    <= 1'b0;
			pending_wr_rsp <= 1'b0;
			pending_rd_rsp <= 1'b0;
		end else begin
			// latch address/data handshake completion
			if (mem_axi_awvalid && mem_axi_awready) ack_awvalid <= 1'b1;
			if (mem_axi_wvalid  && mem_axi_wready ) ack_wvalid  <= 1'b1;
			if (mem_axi_arvalid && mem_axi_arready) ack_arvalid <= 1'b1;

			// once write req sent (AW+W), wait for B
			if (ack_awvalid && ack_wvalid)
				pending_wr_rsp <= 1'b1;

			// once read req sent (AR), wait for R
			if (ack_arvalid)
				pending_rd_rsp <= 1'b1;

			// response consumed
			if (pending_wr_rsp && mem_axi_bvalid && mem_axi_bready) begin
				pending_wr_rsp <= 1'b0;
				ack_awvalid    <= 1'b0;
				ack_wvalid     <= 1'b0;
			end

			if (pending_rd_rsp && mem_axi_rvalid && mem_axi_rready) begin
				pending_rd_rsp <= 1'b0;
				ack_arvalid    <= 1'b0;
			end

			// if core drops mem_valid (abort/new cycle), clear stale req acks
			if (!mem_valid) begin
				ack_awvalid <= 1'b0;
				ack_wvalid  <= 1'b0;
				ack_arvalid <= 1'b0;
				// keep pending_* until response returns, prevents losing B/R
			end
		end
	end

endmodule