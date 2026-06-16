module npu_csr #(
  parameter integer AXI_ID_W   = 8,
  parameter integer AXI_ADDR_W = 32,
  parameter integer AXI_DATA_W = 32,
  parameter integer BASE_ADDR  = 32'h0000_2000, // instance-specific
  parameter integer IS_DMA     = 1              // 1: DMA map, 0: NPU map
)(
  input  wire                      aclk,
  input  wire                      aresetn,

  input  wire                      s_awvalid,
  output reg                       s_awready,
  input  wire [AXI_ADDR_W-1:0]     s_awaddr,
  input  wire [7:0]                s_awlen,
  input  wire [2:0]                s_awsize,
  input  wire [1:0]                s_awburst,
  input  wire [AXI_ID_W-1:0]       s_awid,

  input  wire                      s_wvalid,
  output reg                       s_wready,
  input  wire [AXI_DATA_W-1:0]     s_wdata,
  input  wire [AXI_DATA_W/8-1:0]   s_wstrb,
  input  wire                      s_wlast,

  output reg                       s_bvalid,
  input  wire                      s_bready,
  output reg [1:0]                 s_bresp,
  output reg [AXI_ID_W-1:0]        s_bid,

  input  wire                      s_arvalid,
  output reg                       s_arready,
  input  wire [AXI_ADDR_W-1:0]     s_araddr,
  input  wire [7:0]                s_arlen,
  input  wire [2:0]                s_arsize,
  input  wire [1:0]                s_arburst,
  input  wire [AXI_ID_W-1:0]       s_arid,

  output reg                       s_rvalid,
  input  wire                      s_rready,
  output reg [AXI_DATA_W-1:0]      s_rdata,
  output reg [1:0]                 s_rresp,
  output reg                       s_rlast,
  output reg [AXI_ID_W-1:0]        s_rid
);

  // -------- minimal reg map --------
  // common offsets
  localparam CTRL_OFS   = 12'h000; // [0]start(W1P), [1]irq_en
  localparam STATUS_OFS = 12'h004; // [0]busy, [1]done(W1C)
  localparam SRC_OFS    = 12'h008;
  localparam DST_OFS    = 12'h00C;
  localparam LEN_OFS    = 12'h010;
  localparam CFG_OFS    = 12'h014;

  reg [31:0] reg_ctrl, reg_status, reg_src, reg_dst, reg_len, reg_cfg;
  reg [3:0]  busy_cnt;

  reg [AXI_ADDR_W-1:0] awaddr_q;
  reg [AXI_ID_W-1:0]   awid_q;

  wire [11:0] w_ofs = awaddr_q[11:0];
  wire [11:0] r_ofs = s_araddr[11:0];

  integer b;
  reg [31:0] wmask_data;

  always @(*) begin
    wmask_data = reg_ctrl;
    for (b=0; b<4; b=b+1) begin
      if (s_wstrb[b]) wmask_data[8*b +: 8] = s_wdata[8*b +: 8];
    end
  end

  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      s_awready <= 1'b1; s_wready <= 1'b0; s_bvalid <= 1'b0; s_bresp <= 2'b00; s_bid <= '0;
      s_arready <= 1'b1; s_rvalid <= 1'b0; s_rresp <= 2'b00; s_rid <= '0; s_rlast <= 1'b0; s_rdata <= '0;

      reg_ctrl <= 32'h0;
      reg_status <= 32'h0;
      reg_src <= 32'h0;
      reg_dst <= 32'h0;
      reg_len <= 32'h0;
      reg_cfg <= 32'h0;
      busy_cnt <= 4'd0;
      awaddr_q <= '0;
      awid_q <= '0;
    end else begin
      // fake operation progress: start -> busy 4 cycles -> done
      if (reg_status[0]) begin
        if (busy_cnt != 0) busy_cnt <= busy_cnt - 1'b1;
        else begin
          reg_status[0] <= 1'b0; // busy=0
          reg_status[1] <= 1'b1; // done=1
        end
      end

      // write address
      if (s_awready && s_awvalid) begin
        awaddr_q  <= s_awaddr;
        awid_q    <= s_awid;
        s_awready <= 1'b0;
        s_wready  <= 1'b1;
      end

      // write data
      if (s_wready && s_wvalid) begin
        s_wready <= 1'b0;
        s_bvalid <= 1'b1;
        s_bresp  <= 2'b00;
        s_bid    <= awid_q;

        case (w_ofs)
          CTRL_OFS: begin
            // WSTRB write
            for (b=0; b<4; b=b+1)
              if (s_wstrb[b]) reg_ctrl[8*b +: 8] <= s_wdata[8*b +: 8];

            // bit0=start pulse
            if (s_wstrb[0] && s_wdata[0]) begin
              reg_status[0] <= 1'b1; // busy
              reg_status[1] <= 1'b0; // done clear
              busy_cnt      <= 4'd4;
            end
          end
          STATUS_OFS: begin
            // done W1C
            if (s_wstrb[0] && s_wdata[1]) reg_status[1] <= 1'b0;
          end
          SRC_OFS: begin
            for (b=0; b<4; b=b+1) if (s_wstrb[b]) reg_src[8*b +: 8] <= s_wdata[8*b +: 8];
          end
          DST_OFS: begin
            for (b=0; b<4; b=b+1) if (s_wstrb[b]) reg_dst[8*b +: 8] <= s_wdata[8*b +: 8];
          end
          LEN_OFS: begin
            for (b=0; b<4; b=b+1) if (s_wstrb[b]) reg_len[8*b +: 8] <= s_wdata[8*b +: 8];
          end
          CFG_OFS: begin
            for (b=0; b<4; b=b+1) if (s_wstrb[b]) reg_cfg[8*b +: 8] <= s_wdata[8*b +: 8];
          end
          default: begin end
        endcase
      end

      if (s_bvalid && s_bready) begin
        s_bvalid  <= 1'b0;
        s_awready <= 1'b1;
      end

      // read address
      if (s_arready && s_arvalid) begin
        s_arready <= 1'b0;
        s_rvalid  <= 1'b1;
        s_rresp   <= 2'b00;
        s_rid     <= s_arid;
        s_rlast   <= 1'b1;

        case (r_ofs)
          CTRL_OFS:   s_rdata <= reg_ctrl;
          STATUS_OFS: s_rdata <= reg_status;
          SRC_OFS:    s_rdata <= reg_src;
          DST_OFS:    s_rdata <= reg_dst;
          LEN_OFS:    s_rdata <= reg_len;
          CFG_OFS:    s_rdata <= reg_cfg;
          default:    s_rdata <= 32'hDEAD_0000 | {20'h0, r_ofs};
        endcase
      end

      if (s_rvalid && s_rready) begin
        s_rvalid  <= 1'b0;
        s_rlast   <= 1'b0;
        s_arready <= 1'b1;
      end
    end
  end
endmodule