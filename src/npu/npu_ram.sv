module npu_ram #(
    parameter integer AXI_ID_W   = 8,
    parameter integer AXI_ADDR_W = 32,
    parameter integer AXI_DATA_W = 32,
    parameter integer MEM_BYTES  = 131072,   // 128KB
    parameter integer READ_LATENCY = 1     // >=1
)(
    input  wire                        aclk,
    input  wire                        aresetn,

    // AXI slave write address
    input  wire                        s_awvalid,
    output reg                         s_awready,
    input  wire [AXI_ADDR_W-1:0]       s_awaddr,
    input  wire [7:0]                  s_awlen,
    input  wire [2:0]                  s_awsize,
    input  wire [1:0]                  s_awburst,
    input  wire [AXI_ID_W-1:0]         s_awid,

    // AXI slave write data
    input  wire                        s_wvalid,
    output reg                         s_wready,
    input  wire [AXI_DATA_W-1:0]       s_wdata,
    input  wire [AXI_DATA_W/8-1:0]     s_wstrb,
    input  wire                        s_wlast,

    // AXI slave write response
    output reg                         s_bvalid,
    input  wire                        s_bready,
    output reg [1:0]                   s_bresp,
    output reg [AXI_ID_W-1:0]          s_bid,

    // AXI slave read address
    input  wire                        s_arvalid,
    output reg                         s_arready,
    input  wire [AXI_ADDR_W-1:0]       s_araddr,
    input  wire [7:0]                  s_arlen,
    input  wire [2:0]                  s_arsize,
    input  wire [1:0]                  s_arburst,
    input  wire [AXI_ID_W-1:0]         s_arid,

    // AXI slave read data
    output reg                         s_rvalid,
    input  wire                        s_rready,
    output reg [AXI_DATA_W-1:0]        s_rdata,
    output reg [1:0]                   s_rresp,
    output reg                         s_rlast,
    output reg [AXI_ID_W-1:0]          s_rid,

    // Simple read port (for conv_top im2col, combinational)
    input  wire [AXI_ADDR_W-1:0]       simple_rd_addr,   // byte address
    output wire [AXI_DATA_W-1:0]       simple_rd_data    // 32-bit read data
);

    localparam integer STRB_W = AXI_DATA_W/8;
    localparam integer ADDR_LSB = $clog2(STRB_W);

    // byte-addressable memory
    reg [7:0] mem [0:MEM_BYTES-1];

    // Simple read port (combinational, bypass AXI pipeline)
    assign simple_rd_data = (simple_rd_addr + 3 < MEM_BYTES) ?
        {mem[simple_rd_addr+3], mem[simple_rd_addr+2],
         mem[simple_rd_addr+1], mem[simple_rd_addr]} : 32'h0;

    integer i;
    initial begin
        for (i = 0; i < MEM_BYTES; i = i + 1) mem[i] = 8'h00;
    end

    // ---------------- Write channel state ----------------
    reg wr_active;
    reg [AXI_ADDR_W-1:0] wr_addr;
    reg [7:0]            wr_left;   // remaining beats-1 style
    reg [2:0]            wr_size;
    reg [1:0]            wr_burst;
    reg [AXI_ID_W-1:0]   wr_id;

    // ---------------- Read channel state ----------------
    reg rd_active;
    reg [AXI_ADDR_W-1:0] rd_addr;
    reg [7:0]            rd_left;
    reg [2:0]            rd_size;
    reg [1:0]            rd_burst;
    reg [AXI_ID_W-1:0]   rd_id;
    reg [$clog2(READ_LATENCY+1)-1:0] rd_lat_cnt;

    wire wr_addr_in_range = (wr_addr < MEM_BYTES);
    wire rd_addr_in_range = (rd_addr < MEM_BYTES);

    // write byte helper
    integer b;
    reg [AXI_ADDR_W-1:0] byte_addr;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            // defaults
            s_awready <= 1'b1;
            s_wready  <= 1'b0;
            s_bvalid  <= 1'b0;
            s_bresp   <= 2'b00;
            s_bid     <= '0;

            s_arready <= 1'b1;
            s_rvalid  <= 1'b0;
            s_rdata   <= '0;
            s_rresp   <= 2'b00;
            s_rlast   <= 1'b0;
            s_rid     <= '0;

            wr_active <= 1'b0;
            wr_addr   <= '0;
            wr_left   <= '0;
            wr_size   <= 3'd0;
            wr_burst  <= 2'b01;
            wr_id     <= '0;

            rd_active <= 1'b0;
            rd_addr   <= '0;
            rd_left   <= '0;
            rd_size   <= 3'd0;
            rd_burst  <= 2'b01;
            rd_id     <= '0;
            rd_lat_cnt<= '0;
        end else begin
            // ---------------- AW capture ----------------
            if (s_awready && s_awvalid) begin
                //$display("[NPU_RAM] AW handshake: addr=%0h, len=%0d, id=%0d", s_awaddr, s_awlen, s_awid);
                wr_active <= 1'b1;
                wr_addr   <= s_awaddr;
                wr_left   <= s_awlen;
                wr_size   <= s_awsize;
                wr_burst  <= s_awburst;
                wr_id     <= s_awid;

                s_awready <= 1'b0;
                s_wready  <= 1'b1;
            end

            // ---------------- W accept ----------------
            if (s_wready && s_wvalid) begin
                //$display("[NPU_RAM] W data: beat_addr=%0h, data=%0h, strb=%0b, wlast=%0b, wr_left=%0d", 
             //wr_addr, s_wdata, s_wstrb, s_wlast, wr_left);
                // write strobes by byte
                for (b = 0; b < STRB_W; b = b + 1) begin
                    if (s_wstrb[b]) begin
                        byte_addr = wr_addr + b;
                        if (byte_addr < MEM_BYTES)
                            mem[byte_addr] <= s_wdata[8*b +: 8];
                    end
                end

                // advance burst addr if INCR
                if (wr_burst == 2'b01) begin
                    wr_addr <= wr_addr + (1 << wr_size);
                end

                if (wr_left == 0 || s_wlast) begin
                    //$display("[NPU_RAM] Generate B response: id=%0d, addr=%0h", wr_id, wr_addr);
                    s_wready  <= 1'b0;
                    s_bvalid  <= 1'b1;
                    s_bresp   <= 2'b00; // OKAY
                    s_bid     <= wr_id;
                    wr_active <= 1'b0;
                end else begin
                    wr_left <= wr_left - 1'b1;
                end
            end

            // ---------------- B handshake ----------------
            if (s_bvalid && s_bready) begin
                //$display("[NPU_RAM] B handshake: id=%0d", s_bid);
                s_bvalid  <= 1'b0;
                s_awready <= 1'b1;
            end

            // ---------------- AR capture ----------------
            if (s_arready && s_arvalid) begin
                rd_active  <= 1'b1;
                rd_addr    <= s_araddr;
                rd_left    <= s_arlen;
                rd_size    <= s_arsize;
                rd_burst   <= s_arburst;
                rd_id      <= s_arid;
                rd_lat_cnt <= READ_LATENCY-1;

                s_arready  <= 1'b0;
            end

            // ---------------- R produce ----------------
            if (rd_active && !s_rvalid) begin
                if (rd_lat_cnt != 0) begin
                    rd_lat_cnt <= rd_lat_cnt - 1'b1;
                end else begin
                    // pack data from memory bytes
                    for (b = 0; b < STRB_W; b = b + 1) begin
                        byte_addr = rd_addr + b;
                        s_rdata[8*b +: 8] <= (byte_addr < MEM_BYTES) ? mem[byte_addr] : 8'h00;
                    end
                    s_rvalid <= 1'b1;
                    s_rresp  <= 2'b00;   // OKAY
                    s_rid    <= rd_id;
                    s_rlast  <= (rd_left == 0);
                end
            end

            // ---------------- R handshake ----------------
            if (s_rvalid && s_rready) begin
                s_rvalid <= 1'b0;

                if (rd_left == 0) begin
                    rd_active <= 1'b0;
                    s_arready <= 1'b1;
                    s_rlast   <= 1'b0;
                end else begin
                    rd_left <= rd_left - 1'b1;
                    if (rd_burst == 2'b01)
                        rd_addr <= rd_addr + (1 << rd_size);
                    rd_lat_cnt <= READ_LATENCY-1;
                end
            end
        end
    end

endmodule