module ddr #(
  parameter int DDR_SIZE_BYTES = 67108864, // 64MB
  parameter int AXI_ID_W       = 8,
  parameter int AXI_DATA_W     = 32,
  parameter int AXI_ADDR_W     = 32,
  parameter logic [AXI_ADDR_W-1:0] DDR_BASE = '0,
  parameter [8*128-1:0] DDR_INIT_FILE = ""
)(
  input  logic                     aclk,
  input  logic                     aresetn,   // 低电平有效复位

  // ---------------- AXI4 Slave Interface (仅连接例化中使用的信号) ----------------
  // AW
  input  logic [AXI_ID_W-1:0]      s_awid,
  input  logic [AXI_ADDR_W-1:0]    s_awaddr,
  input  logic [7:0]               s_awlen,
  input  logic [2:0]               s_awsize,
  input  logic [1:0]               s_awburst,
  input  logic                     s_awvalid,
  output logic                     s_awready,

  // W
  input  logic [AXI_DATA_W-1:0]    s_wdata,
  input  logic [AXI_DATA_W/8-1:0]  s_wstrb,
  input  logic                     s_wlast,
  input  logic                     s_wvalid,
  output logic                     s_wready,

  // B
  output logic [AXI_ID_W-1:0]      s_bid,
  output logic [1:0]               s_bresp,
  output logic                     s_bvalid,
  input  logic                     s_bready,

  // AR
  input  logic [AXI_ID_W-1:0]      s_arid,
  input  logic [AXI_ADDR_W-1:0]    s_araddr,
  input  logic [7:0]               s_arlen,
  input  logic [2:0]               s_arsize,
  input  logic [1:0]               s_arburst,
  input  logic                     s_arvalid,
  output logic                     s_arready,

  // R
  output logic [AXI_ID_W-1:0]      s_rid,
  output logic [AXI_DATA_W-1:0]    s_rdata,
  output logic [1:0]               s_rresp,
  output logic                     s_rlast,
  output logic                     s_rvalid,
  input  logic                     s_rready
);

  localparam int AXI_STRB_W = AXI_DATA_W/8;

  // AXI response constants
  localparam logic [1:0] AXI_OKAY   = 2'b00;
  localparam logic [1:0] AXI_EXOKAY = 2'b01;
  localparam logic [1:0] AXI_SLVERR = 2'b10;
  localparam logic [1:0] AXI_DECERR = 2'b11;

  // ---------------- DDR byte array ----------------
  logic [7:0] mem [0:DDR_SIZE_BYTES-1];

  // ---------------- DDR initialization ----------------
  initial begin : INIT_DDR
    integer i;
    for (i = 0; i < DDR_SIZE_BYTES; i = i + 1)
      mem[i] = 8'h00;

    if (DDR_INIT_FILE != "")
      $readmemh(DDR_INIT_FILE, mem);
  end

  // ---------------- Internal state ----------------
  typedef enum logic [1:0] {ST_IDLE, ST_WDATA, ST_WRESP, ST_RDATA} st_t;
  st_t st, st_n;

  logic [AXI_ADDR_W-1:0] awaddr_q, araddr_q;
  logic [7:0]            awlen_q,  arlen_q;
  logic [2:0]            awsize_q, arsize_q;
  logic [1:0]            awburst_q, arburst_q;
  logic [7:0]            wbeat_q, rbeat_q;
  logic [AXI_ID_W-1:0]   awid_q, arid_q;
  logic                  wr_err_q, rd_err_q;
  logic                  rr_sel_ff;

  // ---------------- Address helpers ----------------
  function automatic bit in_range(input logic [AXI_ADDR_W-1:0] a);
    logic [AXI_ADDR_W-1:0] off;
    begin
      if (a < DDR_BASE) begin
        in_range = 1'b0;
      end else begin
        off = a - DDR_BASE;
        in_range = (off < DDR_SIZE_BYTES);
      end
    end
  endfunction

  function automatic logic [AXI_ADDR_W-1:0] to_off(input logic [AXI_ADDR_W-1:0] a);
    begin
      to_off = a - DDR_BASE;
    end
  endfunction

  function automatic bit write_beat(
    input logic [AXI_ADDR_W-1:0] addr_abs,
    input logic [AXI_DATA_W-1:0] data,
    input logic [AXI_STRB_W-1:0] strb
  );
    logic [AXI_ADDR_W-1:0] a, off;
    begin
      write_beat = 1'b1;
      for (int i = 0; i < AXI_STRB_W; i++) begin
        if (strb[i]) begin
          a = addr_abs + i;
          if (!in_range(a)) begin
            write_beat = 1'b0;
          end else begin
            off = to_off(a);
            mem[off] = data[8*i +: 8];
          end
        end
      end
    end
  endfunction

  function automatic bit read_beat(
    input  logic [AXI_ADDR_W-1:0] addr_abs,
    output logic [AXI_DATA_W-1:0] data
  );
    logic [AXI_ADDR_W-1:0] a, off;
    begin
      data = '0;
      for (int i = 0; i < AXI_STRB_W; i++) begin
        a = addr_abs + i;
        if (!in_range(a)) begin
          data = '0;
          return 1'b0;
        end
        off = to_off(a);
        data[8*i +: 8] = mem[off];
      end
      return 1'b1;
    end
  endfunction

  function automatic logic [AXI_ADDR_W-1:0] beat_addr(
    input logic [AXI_ADDR_W-1:0] base,
    input logic [7:0]            beat,
    input logic [2:0]            size,
    input logic [1:0]            burst
  );
    logic [AXI_ADDR_W-1:0] step;
    begin
      step = (beat << size);
      case (burst)
        2'b00: beat_addr = base;        // FIXED
        2'b01: beat_addr = base + step; // INCR
        default: beat_addr = base + step; // WRAP simplified to INCR
      endcase
    end
  endfunction

  // ---------------- Combinational logic ----------------
  always_comb begin
    logic ar_req, aw_req, grant_ar, grant_aw;
    logic [AXI_DATA_W-1:0] rtmp;
    bit rok;

    s_awready = 1'b0;
    s_wready  = 1'b0;
    s_bvalid  = 1'b0;
    s_bresp   = AXI_OKAY;
    s_bid     = awid_q;

    s_arready = 1'b0;
    s_rvalid  = 1'b0;
    s_rdata   = '0;
    s_rresp   = AXI_OKAY;
    s_rlast   = 1'b0;
    s_rid     = arid_q;

    st_n = st;

    case (st)
      ST_IDLE: begin
        ar_req   = s_arvalid;
        aw_req   = s_awvalid;
        grant_ar = 1'b0;
        grant_aw = 1'b0;

        if (ar_req && aw_req) begin
          grant_ar = ~rr_sel_ff;
          grant_aw =  rr_sel_ff;
        end else if (ar_req) begin
          grant_ar = 1'b1;
        end else if (aw_req) begin
          grant_aw = 1'b1;
        end

        s_arready = grant_ar;
        s_awready = grant_aw;

        if (s_arvalid && s_arready)      st_n = ST_RDATA;
        else if (s_awvalid && s_awready) st_n = ST_WDATA;
      end

      ST_WDATA: begin
        s_wready = 1'b1;
        if (s_wvalid && s_wready && s_wlast) st_n = ST_WRESP;
      end

      ST_WRESP: begin
        s_bvalid = 1'b1;
        s_bresp  = wr_err_q ? AXI_SLVERR : AXI_OKAY;
        if (s_bvalid && s_bready) st_n = ST_IDLE;
      end

      ST_RDATA: begin
        s_rvalid = 1'b1;
        rok = read_beat(beat_addr(araddr_q, rbeat_q, arsize_q, arburst_q), rtmp);
        s_rdata = rtmp;
        s_rresp = (rd_err_q || !rok) ? AXI_SLVERR : AXI_OKAY;
        s_rlast = (rbeat_q == arlen_q);
        if (s_rvalid && s_rready && s_rlast) st_n = ST_IDLE;
      end

      default: st_n = ST_IDLE;
    endcase
  end

  // ---------------- Sequential logic ----------------
  always_ff @(posedge aclk) begin
    if (!aresetn) begin   // 低电平复位
      st        <= ST_IDLE;
      rr_sel_ff <= 1'b0;

      awaddr_q  <= '0; araddr_q  <= '0;
      awlen_q   <= '0; arlen_q   <= '0;
      awsize_q  <= '0; arsize_q  <= '0;
      awburst_q <= '0; arburst_q <= '0;
      wbeat_q   <= '0; rbeat_q   <= '0;
      awid_q    <= '0; arid_q    <= '0;
      wr_err_q  <= 1'b0; rd_err_q <= 1'b0;
    end else begin
      st <= st_n;

      if (st == ST_IDLE && s_awvalid && s_awready) begin
        awaddr_q  <= s_awaddr;
        awlen_q   <= s_awlen;
        awsize_q  <= s_awsize;
        awburst_q <= s_awburst;
        awid_q    <= s_awid;
        wbeat_q   <= '0;
        wr_err_q  <= 1'b0;
        rr_sel_ff <= ~rr_sel_ff;
      end

      if (st == ST_IDLE && s_arvalid && s_arready) begin
        araddr_q  <= s_araddr;
        arlen_q   <= s_arlen;
        arsize_q  <= s_arsize;
        arburst_q <= s_arburst;
        arid_q    <= s_arid;
        rbeat_q   <= '0;
        rd_err_q  <= 1'b0;
        rr_sel_ff <= ~rr_sel_ff;
      end

      if (st == ST_WDATA && s_wvalid && s_wready) begin
        bit ok;
        ok = write_beat(beat_addr(awaddr_q, wbeat_q, awsize_q, awburst_q), s_wdata, s_wstrb);
        if (!ok) wr_err_q <= 1'b1;
        if (!s_wlast) wbeat_q <= wbeat_q + 1'b1;
      end

      if (st == ST_RDATA && s_rvalid && s_rready) begin
        logic [AXI_DATA_W-1:0] dummy;
        bit ok;
        ok = read_beat(beat_addr(araddr_q, rbeat_q, arsize_q, arburst_q), dummy);
        if (!ok) rd_err_q <= 1'b1;
        if (rbeat_q != arlen_q) rbeat_q <= rbeat_q + 1'b1;
      end
    end
  end

  // ---------------- Optional preload helpers ----------------
  task automatic mem_fill(input logic [31:0] base, input int nbytes, input byte val);
    logic [31:0] a, off;
    begin
      for (int i = 0; i < nbytes; i++) begin
        a = base + i;
        if (in_range(a)) begin
          off = to_off(a);
          mem[off] = val;
        end
      end
    end
  endtask

  task automatic mem_write_pattern(input logic [31:0] base, input int nbytes, input int seed);
    logic [31:0] a, off;
    begin
      for (int i = 0; i < nbytes; i++) begin
        a = base + i;
        if (in_range(a)) begin
          off = to_off(a);
          mem[off] = (i + seed) % 256;
        end
      end
    end
  endtask

endmodule