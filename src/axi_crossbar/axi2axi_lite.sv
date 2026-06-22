// =============================================================================
// AXI4 to AXI4-Lite Bridge (with prot signal passthrough)
// =============================================================================
module axi2axi_lite #(
    parameter integer DATA_WIDTH = 32,
    parameter integer ADDR_WIDTH = 32,
    parameter integer ID_WIDTH   = 8
) (
    input  wire                      aclk,
    input  wire                      aresetn,

    // ------------------------------------------------------------
    // AXI4 Slave (面向 AXI4-Only Interconnect)
    // ------------------------------------------------------------
    input  wire [ID_WIDTH-1:0]       s_axi_awid,
    input  wire [ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire [7:0]                s_axi_awlen,
    input  wire [2:0]                s_axi_awsize,
    input  wire [1:0]                s_axi_awburst,
    input  wire                      s_axi_awlock,
    input  wire [3:0]                s_axi_awcache,
    input  wire [2:0]                s_axi_awprot,     // <-- 新增
    input  wire [3:0]                s_axi_awqos,
    input  wire [3:0]                s_axi_awregion,
    input  wire                      s_axi_awvalid,
    output wire                      s_axi_awready,

    input  wire [ID_WIDTH-1:0]       s_axi_wid,
    input  wire [DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0]   s_axi_wstrb,
    input  wire                      s_axi_wlast,
    input  wire                      s_axi_wvalid,
    output wire                      s_axi_wready,

    output wire [ID_WIDTH-1:0]       s_axi_bid,
    output wire [1:0]                s_axi_bresp,
    output wire                      s_axi_bvalid,
    input  wire                      s_axi_bready,

    input  wire [ID_WIDTH-1:0]       s_axi_arid,
    input  wire [ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire [7:0]                s_axi_arlen,
    input  wire [2:0]                s_axi_arsize,
    input  wire [1:0]                s_axi_arburst,
    input  wire                      s_axi_arlock,
    input  wire [3:0]                s_axi_arcache,
    input  wire [2:0]                s_axi_arprot,     // <-- 新增
    input  wire [3:0]                s_axi_arqos,
    input  wire [3:0]                s_axi_arregion,
    input  wire                      s_axi_arvalid,
    output wire                      s_axi_arready,

    output wire [ID_WIDTH-1:0]       s_axi_rid,
    output wire [DATA_WIDTH-1:0]     s_axi_rdata,
    output wire [1:0]                s_axi_rresp,
    output wire                      s_axi_rlast,
    output wire                      s_axi_rvalid,
    input  wire                      s_axi_rready,

    // ------------------------------------------------------------
    // AXI4-Lite Master (面向寄存器模块)
    // ------------------------------------------------------------
    output wire [ADDR_WIDTH-1:0]     m_axi_lite_awaddr,
    output wire [2:0]                m_axi_lite_awprot, // <-- 新增
    output wire                      m_axi_lite_awvalid,
    input  wire                      m_axi_lite_awready,

    output wire [DATA_WIDTH-1:0]     m_axi_lite_wdata,
    output wire [DATA_WIDTH/8-1:0]   m_axi_lite_wstrb,
    output wire                      m_axi_lite_wvalid,
    input  wire                      m_axi_lite_wready,

    input  wire [1:0]                m_axi_lite_bresp,
    input  wire                      m_axi_lite_bvalid,
    output wire                      m_axi_lite_bready,

    output wire [ADDR_WIDTH-1:0]     m_axi_lite_araddr,
    output wire [2:0]                m_axi_lite_arprot, // <-- 新增
    output wire                      m_axi_lite_arvalid,
    input  wire                      m_axi_lite_arready,

    input  wire [DATA_WIDTH-1:0]     m_axi_lite_rdata,
    input  wire [1:0]                m_axi_lite_rresp,
    input  wire                      m_axi_lite_rvalid,
    output wire                      m_axi_lite_rready
);

    // ------------------------------------------------------------
    // 内部信号定义
    // ------------------------------------------------------------
    localparam WR_IDLE = 2'd0, WR_ADDR = 2'd1, WR_DATA = 2'd2, WR_RESP = 2'd3;
    localparam RD_IDLE = 2'd0, RD_ADDR = 2'd1, RD_DATA = 2'd2;

    reg [1:0] wr_state, rd_state;

    // 写通道缓冲
    reg [ID_WIDTH-1:0]     awid_q;
    reg [ADDR_WIDTH-1:0]   awaddr_q;
    reg [2:0]              awprot_q;         // <-- 新增
    reg [DATA_WIDTH-1:0]   wdata_q;
    reg [DATA_WIDTH/8-1:0] wstrb_q;
    reg                    error_aw;

    // 读通道缓冲
    reg [ID_WIDTH-1:0]     arid_q;
    reg [ADDR_WIDTH-1:0]   araddr_q;
    reg [2:0]              arprot_q;         // <-- 新增
    reg                    error_ar;

    // 响应寄存器
    reg [ID_WIDTH-1:0]     bid_q;
    reg [1:0]              bresp_q;
    reg                    bvalid_q;

    reg [ID_WIDTH-1:0]     rid_q;
    reg [DATA_WIDTH-1:0]   rdata_q;
    reg [1:0]              rresp_q;
    reg                    rvalid_q, rlast_q;

    // 突发长度错误检测
    wire awlen_err = (s_axi_awlen != 8'd0);
    wire arlen_err = (s_axi_arlen != 8'd0);

    // ------------------------------------------------------------
    // AXI4-Lite Master 输出连接
    // ------------------------------------------------------------
    assign m_axi_lite_awaddr  = awaddr_q;
    assign m_axi_lite_awprot  = awprot_q;
    assign m_axi_lite_awvalid = (wr_state == WR_ADDR) && !error_aw;

    assign m_axi_lite_wdata   = wdata_q;
    assign m_axi_lite_wstrb   = wstrb_q;
    assign m_axi_lite_wvalid  = (wr_state == WR_DATA) && !error_aw;

    assign m_axi_lite_araddr  = araddr_q;
    assign m_axi_lite_arprot  = arprot_q;
    assign m_axi_lite_arvalid = (rd_state == RD_ADDR) && !error_ar;

    // AXI4 从设备 Ready 信号
    assign s_axi_awready = (wr_state == WR_IDLE);
    assign s_axi_wready  = (wr_state == WR_DATA) && m_axi_lite_wready;
    assign s_axi_arready = (rd_state == RD_IDLE);

    assign m_axi_lite_bready = (wr_state == WR_RESP) && s_axi_bready;
    assign m_axi_lite_rready = (rd_state == RD_DATA) && s_axi_rready;

    // AXI4 响应通道
    assign s_axi_bid    = bid_q;
    assign s_axi_bresp  = bresp_q;
    assign s_axi_bvalid = bvalid_q;

    assign s_axi_rid    = rid_q;
    assign s_axi_rdata  = rdata_q;
    assign s_axi_rresp  = rresp_q;
    assign s_axi_rvalid = rvalid_q;
    assign s_axi_rlast  = rlast_q;

    // ------------------------------------------------------------
    // 写通道状态机
    // ------------------------------------------------------------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_state <= WR_IDLE;
            awid_q   <= '0;
            awaddr_q <= '0;
            awprot_q <= '0;
            wdata_q  <= '0;
            wstrb_q  <= '0;
            error_aw <= 1'b0;
            bid_q    <= '0;
            bresp_q  <= 2'b00;
            bvalid_q <= 1'b0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    if (s_axi_awvalid && s_axi_awready) begin
                        awid_q   <= s_axi_awid;
                        awaddr_q <= s_axi_awaddr;
                        awprot_q <= s_axi_awprot;   // 捕获 prot
                        error_aw <= awlen_err;
                        wr_state <= WR_ADDR;
                    end
                end

                WR_ADDR: begin
                    if (m_axi_lite_awvalid && m_axi_lite_awready) begin
                        wr_state <= WR_DATA;
                    end
                end

                WR_DATA: begin
                    if (s_axi_wvalid && s_axi_wready) begin
                        wdata_q  <= s_axi_wdata;
                        wstrb_q  <= s_axi_wstrb;
                        wr_state <= WR_RESP;
                    end
                end

                WR_RESP: begin
                    if (m_axi_lite_bvalid && m_axi_lite_bready) begin
                        bid_q    <= awid_q;
                        bresp_q  <= error_aw ? 2'b10 : m_axi_lite_bresp;  // SLVERR if burst
                        bvalid_q <= 1'b1;
                    end

                    if (bvalid_q && s_axi_bready) begin
                        bvalid_q <= 1'b0;
                        wr_state <= WR_IDLE;
                    end
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------
    // 读通道状态机
    // ------------------------------------------------------------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_state <= RD_IDLE;
            arid_q   <= '0;
            araddr_q <= '0;
            arprot_q <= '0;
            error_ar <= 1'b0;
            rid_q    <= '0;
            rdata_q  <= '0;
            rresp_q  <= 2'b00;
            rvalid_q <= 1'b0;
            rlast_q  <= 1'b0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    if (s_axi_arvalid && s_axi_arready) begin
                        arid_q   <= s_axi_arid;
                        araddr_q <= s_axi_araddr;
                        arprot_q <= s_axi_arprot;   // 捕获 prot
                        error_ar <= arlen_err;
                        rd_state <= RD_ADDR;
                    end
                end

                RD_ADDR: begin
                    if (m_axi_lite_arvalid && m_axi_lite_arready) begin
                        rd_state <= RD_DATA;
                    end
                end

                RD_DATA: begin
                    if (m_axi_lite_rvalid && m_axi_lite_rready) begin
                        rid_q    <= arid_q;
                        rdata_q  <= m_axi_lite_rdata;
                        rresp_q  <= error_ar ? 2'b10 : m_axi_lite_rresp;
                        rlast_q  <= 1'b1;
                        rvalid_q <= 1'b1;
                    end

                    if (rvalid_q && s_axi_rready) begin
                        rvalid_q <= 1'b0;
                        rd_state <= RD_IDLE;
                    end
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

endmodule