// =============================================================================
// AXI4 to Simple CSR Bridge
// Converts AXI4 single-beat transactions to a simple register interface.
// Write: captures AW+W together, issues B response next cycle.
// Read:  captures AR, returns R with data next cycle.
// =============================================================================
module axi2csr #(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_ID_W   = 8,
    parameter int CSR_ADDR_W = 8
)(
    input  logic clk,
    input  logic rst_n,

    // AXI4 Slave (from crossbar)
    input  logic                    s_awvalid,
    output logic                    s_awready,
    input  logic [AXI_ADDR_W-1:0]  s_awaddr,
    input  logic [7:0]             s_awlen,
    input  logic [2:0]             s_awsize,
    input  logic [AXI_ID_W-1:0]   s_awid,

    input  logic                    s_wvalid,
    output logic                    s_wready,
    input  logic [AXI_DATA_W-1:0]  s_wdata,
    input  logic [AXI_DATA_W/8-1:0] s_wstrb,
    input  logic                    s_wlast,

    output logic                    s_bvalid,
    input  logic                    s_bready,
    output logic [1:0]             s_bresp,
    output logic [AXI_ID_W-1:0]   s_bid,

    input  logic                    s_arvalid,
    output logic                    s_arready,
    input  logic [AXI_ADDR_W-1:0]  s_araddr,
    input  logic [7:0]             s_arlen,
    input  logic [2:0]             s_arsize,
    input  logic [AXI_ID_W-1:0]   s_arid,

    output logic                    s_rvalid,
    input  logic                    s_rready,
    output logic [AXI_DATA_W-1:0]  s_rdata,
    output logic [1:0]             s_rresp,
    output logic                    s_rlast,
    output logic [AXI_ID_W-1:0]   s_rid,

    // Simple CSR Master (to NPU)
    output logic                    csr_wr_en,
    output logic                    csr_rd_en,
    output logic [CSR_ADDR_W-1:0]  csr_addr,
    output logic [AXI_DATA_W-1:0]  csr_wdata,
    input  logic [AXI_DATA_W-1:0]  csr_rdata
);

    // Internal registers
    logic                  bvalid_r, rvalid_r;
    logic [AXI_ID_W-1:0]  bid_r, rid_r;
    logic [AXI_DATA_W-1:0] rdata_r;
    logic [CSR_ADDR_W-1:0] addr_r;

    // Idle: no pending response
    wire idle = !bvalid_r && !rvalid_r;

    // Accept write when both AW and W are present and idle
    wire wr_accept = idle && s_awvalid && s_wvalid;
    // Accept read when AR is present, no write pending, and idle
    wire rd_accept = idle && s_arvalid && !s_awvalid;

    // AXI4 ready signals
    assign s_awready = wr_accept;
    assign s_wready  = wr_accept;
    assign s_arready = rd_accept;

    // CSR outputs
    assign csr_wr_en = wr_accept;
    assign csr_rd_en = rd_accept;
    assign csr_addr  = wr_accept ? s_awaddr[CSR_ADDR_W-1:0] :
                       rd_accept ? s_araddr[CSR_ADDR_W-1:0] : addr_r;
    assign csr_wdata = s_wdata;

    // AXI4 response signals
    assign s_bvalid = bvalid_r;
    assign s_bresp  = 2'b00;  // OKAY
    assign s_bid    = bid_r;

    assign s_rvalid = rvalid_r;
    assign s_rdata  = rdata_r;
    assign s_rresp  = 2'b00;  // OKAY
    assign s_rlast  = 1'b1;
    assign s_rid    = rid_r;

    // Sequential logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bvalid_r <= 1'b0;
            rvalid_r <= 1'b0;
            bid_r    <= '0;
            rid_r    <= '0;
            rdata_r  <= '0;
            addr_r   <= '0;
        end else begin
            // Clear on handshake
            if (bvalid_r && s_bready)
                bvalid_r <= 1'b0;
            if (rvalid_r && s_rready)
                rvalid_r <= 1'b0;

            // Write: latch ID, issue B next cycle
            if (wr_accept) begin
                bid_r    <= s_awid;
                bvalid_r <= 1'b1;
                addr_r   <= s_awaddr[CSR_ADDR_W-1:0];
            end

            // Read: latch ID + data, issue R next cycle
            if (rd_accept) begin
                rid_r    <= s_arid;
                rvalid_r <= 1'b1;
                rdata_r  <= csr_rdata;
                addr_r   <= s_araddr[CSR_ADDR_W-1:0];
            end
        end
    end

endmodule
