module axi_lite2axi #(
    parameter integer DATA_WIDTH = 32,
    parameter integer ADDR_WIDTH = 32,
    parameter integer ID_WIDTH   = 8,
    parameter [ID_WIDTH-1:0] M_AXI_ID = 8'h10
) (
    input  wire                      aclk,
    input  wire                      aresetn,

    // AXI4-Lite slave
    input  wire [ADDR_WIDTH-1:0]     s_axi_lite_awaddr,
    input  wire                      s_axi_lite_awvalid,
    output wire                      s_axi_lite_awready,
    input  wire [DATA_WIDTH-1:0]     s_axi_lite_wdata,
    input  wire [DATA_WIDTH/8-1:0]   s_axi_lite_wstrb,
    input  wire                      s_axi_lite_wvalid,
    output wire                      s_axi_lite_wready,
    output wire [1:0]                s_axi_lite_bresp,
    output wire                      s_axi_lite_bvalid,
    input  wire                      s_axi_lite_bready,

    input  wire [ADDR_WIDTH-1:0]     s_axi_lite_araddr,
    input  wire                      s_axi_lite_arvalid,
    output wire                      s_axi_lite_arready,
    output wire [DATA_WIDTH-1:0]     s_axi_lite_rdata,
    output wire [1:0]                s_axi_lite_rresp,
    output wire                      s_axi_lite_rvalid,
    input  wire                      s_axi_lite_rready,

    // AXI4 master
    output wire [ID_WIDTH-1:0]       m_axi_awid,
    output wire [ADDR_WIDTH-1:0]     m_axi_awaddr,
    output wire [7:0]                m_axi_awlen,
    output wire [2:0]                m_axi_awsize,
    output wire [1:0]                m_axi_awburst,
    output wire                      m_axi_awvalid,
    input  wire                      m_axi_awready,

    output wire [ID_WIDTH-1:0]       m_axi_wid,     // keep for compatibility
    output wire [DATA_WIDTH-1:0]     m_axi_wdata,
    output wire [DATA_WIDTH/8-1:0]   m_axi_wstrb,
    output wire                      m_axi_wlast,
    output wire                      m_axi_wvalid,
    input  wire                      m_axi_wready,

    input  wire [ID_WIDTH-1:0]       m_axi_bid,
    input  wire [1:0]                m_axi_bresp,
    input  wire                      m_axi_bvalid,
    output wire                      m_axi_bready,

    output wire [ID_WIDTH-1:0]       m_axi_arid,
    output wire [ADDR_WIDTH-1:0]     m_axi_araddr,
    output wire [7:0]                m_axi_arlen,
    output wire [2:0]                m_axi_arsize,
    output wire [1:0]                m_axi_arburst,
    output wire                      m_axi_arvalid,
    input  wire                      m_axi_arready,

    input  wire [ID_WIDTH-1:0]       m_axi_rid,
    input  wire [DATA_WIDTH-1:0]     m_axi_rdata,
    input  wire [1:0]                m_axi_rresp,
    input  wire                      m_axi_rlast,
    input  wire                      m_axi_rvalid,
    output wire                      m_axi_rready
);

/*
always @(posedge aclk) begin
  if (m_axi_awvalid && m_axi_awready) $display("[BRIDGE_INT] AW HS t=%0t addr=%08h", $time, m_axi_awaddr);
  if (m_axi_wvalid  && m_axi_wready ) $display("[BRIDGE_INT] W  HS t=%0t data=%08h strb=%h", $time, m_axi_wdata, m_axi_wstrb);
  if (m_axi_bvalid  && m_axi_bready ) $display("[BRIDGE_INT] B  HS t=%0t resp=%b", $time, m_axi_bresp);
  if (m_axi_arvalid && m_axi_arready) $display("[BRIDGE_INT] AR HS t=%0t addr=%08h", $time, m_axi_araddr);
  if (m_axi_rvalid  && m_axi_rready ) $display("[BRIDGE_INT] R  HS t=%0t data=%08h resp=%b", $time, m_axi_rdata, m_axi_rresp);
  if (m_axi_awvalid && m_axi_awready) $display("[BRIDGE_ID] AWID=%0d", m_axi_awid);
  if (m_axi_bvalid  && m_axi_bready ) $display("[BRIDGE_ID] BID =%0d", m_axi_bid);
end
*/
// ------------------------------------------------------------
// constants
// ------------------------------------------------------------
localparam [2:0] AXSIZE = $clog2(DATA_WIDTH/8);

assign m_axi_awid    = M_AXI_ID;
assign m_axi_wid     = M_AXI_ID;
assign m_axi_arid    = M_AXI_ID;
assign m_axi_awlen   = 8'd0;
assign m_axi_arlen   = 8'd0;
assign m_axi_awsize  = AXSIZE;
assign m_axi_arsize  = AXSIZE;
assign m_axi_awburst = 2'b01; // INCR
assign m_axi_arburst = 2'b01; // INCR
assign m_axi_wlast   = 1'b1;

// ------------------------------------------------------------
// write channel
// ------------------------------------------------------------
localparam [1:0] WR_IDLE=2'd0, WR_SEND=2'd1, WR_RESP=2'd2;
reg [1:0] wr_state;

reg                    aw_buf_v, w_buf_v;
reg [ADDR_WIDTH-1:0]   awaddr_q;
reg [DATA_WIDTH-1:0]   wdata_q;
reg [DATA_WIDTH/8-1:0] wstrb_q;
reg                    aw_sent, w_sent;

reg                    b_v;
reg [1:0]              bresp_q;

assign s_axi_lite_awready = (wr_state == WR_IDLE) && !aw_buf_v;
assign s_axi_lite_wready  = (wr_state == WR_IDLE) && !w_buf_v;

assign m_axi_awvalid = (wr_state == WR_SEND) && aw_buf_v && !aw_sent;
assign m_axi_wvalid  = (wr_state == WR_SEND) && w_buf_v  && !w_sent;
assign m_axi_awaddr  = awaddr_q;
assign m_axi_wdata   = wdata_q;
assign m_axi_wstrb   = wstrb_q;

// hold ready in WR_RESP; latch one B and hold to lite side until accepted
assign m_axi_bready      = (wr_state == WR_RESP) && !b_v;
assign s_axi_lite_bvalid = b_v;
assign s_axi_lite_bresp  = bresp_q;

// ------------------------------------------------------------
// read channel
// ------------------------------------------------------------
localparam [1:0] RD_IDLE=2'd0, RD_SEND=2'd1, RD_RESP=2'd2;
reg [1:0] rd_state;

reg                  ar_buf_v;
reg [ADDR_WIDTH-1:0] araddr_q;

reg                  r_v;
reg [DATA_WIDTH-1:0] rdata_q;
reg [1:0]            rresp_q;

assign s_axi_lite_arready = (rd_state == RD_IDLE) && !ar_buf_v;
assign m_axi_arvalid      = (rd_state == RD_SEND) && ar_buf_v;
assign m_axi_araddr       = araddr_q;

assign m_axi_rready       = (rd_state == RD_RESP) && !r_v;
assign s_axi_lite_rvalid  = r_v;
assign s_axi_lite_rdata   = rdata_q;
assign s_axi_lite_rresp   = rresp_q;

// ------------------------------------------------------------
// sequential
// ------------------------------------------------------------
always @(posedge aclk or negedge aresetn) begin
  if (!aresetn) begin
    wr_state <= WR_IDLE;
    aw_buf_v <= 1'b0; w_buf_v <= 1'b0;
    awaddr_q <= '0;   wdata_q <= '0; wstrb_q <= '0;
    aw_sent  <= 1'b0; w_sent  <= 1'b0;
    b_v      <= 1'b0; bresp_q <= 2'b00;

    rd_state <= RD_IDLE;
    ar_buf_v <= 1'b0; araddr_q <= '0;
    r_v      <= 1'b0; rdata_q  <= '0; rresp_q <= 2'b00;
  end else begin
    // ---------------- write FSM ----------------
    case (wr_state)
      WR_IDLE: begin
        // capture independently
        if (s_axi_lite_awvalid && s_axi_lite_awready) begin
          aw_buf_v <= 1'b1;
          awaddr_q <= s_axi_lite_awaddr;
        end
        if (s_axi_lite_wvalid && s_axi_lite_wready) begin
          w_buf_v  <= 1'b1;
          wdata_q  <= s_axi_lite_wdata;
          wstrb_q  <= s_axi_lite_wstrb;
        end

        // once both captured, go send
        if ((aw_buf_v || (s_axi_lite_awvalid && s_axi_lite_awready)) &&
            (w_buf_v  || (s_axi_lite_wvalid  && s_axi_lite_wready ))) begin
          aw_sent  <= 1'b0;
          w_sent   <= 1'b0;
          b_v      <= 1'b0;
          wr_state <= WR_SEND;
        end
      end

      WR_SEND: begin
        if (!aw_sent && m_axi_awvalid && m_axi_awready) aw_sent <= 1'b1;
        if (!w_sent  && m_axi_wvalid  && m_axi_wready ) w_sent  <= 1'b1;

        // advance only when both actually sent
        if (aw_sent && w_sent)
          wr_state <= WR_RESP;
      end

      WR_RESP: begin
        // latch one B response
        if (!b_v && m_axi_bvalid) begin
          b_v     <= 1'b1;
          bresp_q <= m_axi_bresp;
        end

        // finish lite B handshake
        if (b_v && s_axi_lite_bready) begin
          b_v      <= 1'b0;
          aw_buf_v <= 1'b0;
          w_buf_v  <= 1'b0;
          aw_sent  <= 1'b0;
          w_sent   <= 1'b0;
          wr_state <= WR_IDLE;
        end
      end

      default: wr_state <= WR_IDLE;
    endcase

    // ---------------- read FSM ----------------
    case (rd_state)
      RD_IDLE: begin
        if (s_axi_lite_arvalid && s_axi_lite_arready) begin
          ar_buf_v <= 1'b1;
          araddr_q <= s_axi_lite_araddr;
          rd_state <= RD_SEND;
        end
      end

      RD_SEND: begin
        if (m_axi_arvalid && m_axi_arready) begin
          ar_buf_v <= 1'b0;
          r_v      <= 1'b0;
          rd_state <= RD_RESP;
        end
      end

      RD_RESP: begin
        if (!r_v && m_axi_rvalid) begin
          r_v     <= 1'b1;
          rdata_q <= m_axi_rdata;
          rresp_q <= m_axi_rresp;
        end

        if (r_v && s_axi_lite_rready) begin
          r_v      <= 1'b0;
          rd_state <= RD_IDLE;
        end
      end

      default: rd_state <= RD_IDLE;
    endcase
  end
end

endmodule