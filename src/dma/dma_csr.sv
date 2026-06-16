`include "inc/amba_axi.svh"
`include "inc/dma_pkg.svh"

module dma_csr
  import amba_axi_pkg::*;
  import dma_utils_pkg::*;
#(
  parameter int ID_WIDTH       = `AXI_TXN_ID_WIDTH,
  parameter int ADDRESS_WIDTH  = `AXI_ADDR_WIDTH,
  parameter int DATA_WIDTH     = `AXI_DATA_WIDTH
)(
  input  logic                     i_clk,
  input  logic                     i_rst_n,

  // AXI4-Lite slave
  input  logic                     i_awvalid,
  output logic                     o_awready,
  input  logic [ID_WIDTH-1:0]      i_awid,
  input  logic [ADDRESS_WIDTH-1:0] i_awaddr,
  input  logic [2:0]               i_awprot,

  input  logic                     i_wvalid,
  output logic                     o_wready,
  input  logic [DATA_WIDTH-1:0]    i_wdata,
  input  logic [DATA_WIDTH/8-1:0]  i_wstrb,

  output logic                     o_bvalid,
  input  logic                     i_bready,
  output logic [ID_WIDTH-1:0]      o_bid,
  output axi_resp_t                o_bresp,

  input  logic                     i_arvalid,
  output logic                     o_arready,
  input  logic [ID_WIDTH-1:0]      i_arid,
  input  logic [ADDRESS_WIDTH-1:0] i_araddr,
  input  logic [2:0]               i_arprot,

  output logic                     o_rvalid,
  input  logic                     i_rready,
  output logic [ID_WIDTH-1:0]      o_rid,
  output logic [DATA_WIDTH-1:0]    o_rdata,
  output axi_resp_t                o_rresp,

  // DMA ctrl/status
  output logic                     o_dma_control_go,
  output logic [7:0]               o_dma_control_max_burst,
  output logic                     o_dma_control_abort,

  input  logic                     i_dma_status_done,
  input  logic                     i_dma_error_stats_error_trig,
  input  logic [31:0]              i_dma_error_addr_error_addr,
  input  logic                     i_dma_error_stats_error_type,
  input  logic                     i_dma_error_stats_error_src,

  output logic [1:0][31:0]         o_dma_desc_src_addr_src_addr,
  output logic [1:0][31:0]         o_dma_desc_dst_addr_dst_addr,
  output logic [1:0][31:0]         o_dma_desc_num_bytes_num_bytes,
  output logic [1:0]               o_dma_desc_cfg_write_mode,
  output logic [1:0]               o_dma_desc_cfg_read_mode,
  output logic [1:0]               o_dma_desc_cfg_enable
);

  localparam axi_resp_t AXI_RESP_OKAY   = AXI_OKAY;
  localparam axi_resp_t AXI_RESP_SLVERR = AXI_SLVERR;

  // CSR offsets
  localparam logic [7:0] A_CONTROL     = 8'h00;
  localparam logic [7:0] A_STATUS      = 8'h08;
  localparam logic [7:0] A_ERROR_ADDR  = 8'h10;
  localparam logic [7:0] A_ERROR_STATS = 8'h18;

  localparam logic [7:0] A_SRC0        = 8'h20;
  localparam logic [7:0] A_SRC1_32     = 8'h24;
  localparam logic [7:0] A_SRC1_64     = 8'h28;

  localparam logic [7:0] A_DST0        = 8'h30;
  localparam logic [7:0] A_DST1_32     = 8'h34;
  localparam logic [7:0] A_DST1_64     = 8'h38;

  localparam logic [7:0] A_NUM0        = 8'h40;
  localparam logic [7:0] A_NUM1_32     = 8'h44;
  localparam logic [7:0] A_NUM1_64     = 8'h48;

  localparam logic [7:0] A_CFG0        = 8'h50;
  localparam logic [7:0] A_CFG1_32     = 8'h54;
  localparam logic [7:0] A_CFG1_64     = 8'h58;

  // write holding
  logic [ID_WIDTH-1:0]         awid_q;
  logic [ADDRESS_WIDTH-1:0]    awaddr_q;
  logic [DATA_WIDTH-1:0]       wdata_q;
  logic [DATA_WIDTH/8-1:0]     wstrb_q;
  logic                        aw_hold, w_hold;

  // read holding
  logic [ID_WIDTH-1:0]         arid_q;

  // response regs
  logic                        bvalid_q, rvalid_q;
  axi_resp_t                   bresp_q, rresp_q;
  logic [DATA_WIDTH-1:0]       rdata_q;

  // CSR regs
  logic              reg_go;
  logic              reg_abort;
  logic [7:0]        reg_max_burst;
  logic [1:0][31:0]  reg_src_addr;
  logic [1:0][31:0]  reg_dst_addr;
  logic [1:0][31:0]  reg_num_bytes;
  logic [1:0]        reg_wr_mode;
  logic [1:0]        reg_rd_mode;
  logic [1:0]        reg_enable;

  assign o_dma_control_go               = reg_go;
  assign o_dma_control_abort            = reg_abort;
  assign o_dma_control_max_burst        = reg_max_burst;
  assign o_dma_desc_src_addr_src_addr   = reg_src_addr;
  assign o_dma_desc_dst_addr_dst_addr   = reg_dst_addr;
  assign o_dma_desc_num_bytes_num_bytes = reg_num_bytes;
  assign o_dma_desc_cfg_write_mode      = reg_wr_mode;
  assign o_dma_desc_cfg_read_mode       = reg_rd_mode;
  assign o_dma_desc_cfg_enable          = reg_enable;

  assign o_awready = ~aw_hold;
  assign o_wready  = ~w_hold;
  assign o_bvalid  = bvalid_q;
  assign o_bresp   = bresp_q;
  assign o_bid     = awid_q;

  assign o_arready = ~rvalid_q;
  assign o_rvalid  = rvalid_q;
  assign o_rresp   = rresp_q;
  assign o_rid     = arid_q;
  assign o_rdata   = rdata_q;

  function automatic [DATA_WIDTH-1:0] fn_apply_wstrb(
    input [DATA_WIDTH-1:0] oldv,
    input [DATA_WIDTH-1:0] newv,
    input [DATA_WIDTH/8-1:0] strb
  );
    integer k;
    begin
      fn_apply_wstrb = oldv;
      for (k = 0; k < DATA_WIDTH/8; k = k + 1)
        if (strb[k]) fn_apply_wstrb[k*8 +: 8] = newv[k*8 +: 8];
    end
  endfunction

  function automatic logic fn_addr_high_zero(input logic [ADDRESS_WIDTH-1:0] a);
    if (ADDRESS_WIDTH <= 8) fn_addr_high_zero = 1'b1;
    else                    fn_addr_high_zero = (a[ADDRESS_WIDTH-1:8] == '0);
  endfunction

  // 支持 32-bit 或 64-bit 描述符步进，因此不强制8字节对齐，只要求4字节对齐
  function automatic logic fn_addr_aligned_4(input logic [ADDRESS_WIDTH-1:0] a);
    fn_addr_aligned_4 = (a[1:0] == 2'b00);
  endfunction

  function automatic logic fn_desc_is_1(input logic [7:0] a);
    begin
      unique case (a)
        A_SRC1_32, A_SRC1_64,
        A_DST1_32, A_DST1_64,
        A_NUM1_32, A_NUM1_64,
        A_CFG1_32, A_CFG1_64: fn_desc_is_1 = 1'b1;
        default:              fn_desc_is_1 = 1'b0;
      endcase
    end
  endfunction

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      aw_hold   <= 1'b0;
      w_hold    <= 1'b0;
      awid_q    <= '0;
      awaddr_q  <= '0;
      wdata_q   <= '0;
      wstrb_q   <= '0;

      arid_q    <= '0;

      bvalid_q  <= 1'b0;
      bresp_q   <= AXI_RESP_OKAY;
      rvalid_q  <= 1'b0;
      rresp_q   <= AXI_RESP_OKAY;
      rdata_q   <= '0;

      reg_go        <= 1'b0;
      reg_abort     <= 1'b0;
      reg_max_burst <= 8'hFF;
      reg_src_addr  <= '{default:'0};
      reg_dst_addr  <= '{default:'0};
      reg_num_bytes <= '{default:'0};
      reg_wr_mode   <= '0;
      reg_rd_mode   <= '0;
      reg_enable    <= '0;
    end else begin
      // capture AW
      if (!aw_hold && i_awvalid) begin
        aw_hold  <= 1'b1;
        awid_q   <= i_awid;
        awaddr_q <= i_awaddr;
      end

      // capture W
      if (!w_hold && i_wvalid) begin
        w_hold  <= 1'b1;
        wdata_q <= i_wdata;
        wstrb_q <= i_wstrb;
      end

      // write execute
      if (aw_hold && w_hold && !bvalid_q) begin
        logic [DATA_WIDTH-1:0] old_data_v, new_data_v;
        int unsigned idx_v;

        bresp_q   <= AXI_RESP_OKAY;
        old_data_v = '0;
        new_data_v = '0;
        idx_v      = 0;

        if (!fn_addr_high_zero(awaddr_q) || !fn_addr_aligned_4(awaddr_q)) begin
          bresp_q <= AXI_RESP_SLVERR;
        end else begin
          unique case (awaddr_q[7:0])
            A_CONTROL: begin
              old_data_v[0]   = reg_go;
              old_data_v[1]   = reg_abort;
              old_data_v[9:2] = reg_max_burst;
              new_data_v      = fn_apply_wstrb(old_data_v, wdata_q, wstrb_q);
              reg_go          <= new_data_v[0];
              reg_abort       <= new_data_v[1];
              reg_max_burst   <= new_data_v[9:2];
            end

            A_SRC0, A_SRC1_32, A_SRC1_64: begin
              idx_v = fn_desc_is_1(awaddr_q[7:0]);
              old_data_v = {{(DATA_WIDTH-32){1'b0}}, reg_src_addr[idx_v]};
              new_data_v = fn_apply_wstrb(old_data_v, wdata_q, wstrb_q);
              reg_src_addr[idx_v] <= new_data_v[31:0];
            end

            A_DST0, A_DST1_32, A_DST1_64: begin
              idx_v = fn_desc_is_1(awaddr_q[7:0]);
              old_data_v = {{(DATA_WIDTH-32){1'b0}}, reg_dst_addr[idx_v]};
              new_data_v = fn_apply_wstrb(old_data_v, wdata_q, wstrb_q);
              reg_dst_addr[idx_v] <= new_data_v[31:0];
            end

            A_NUM0, A_NUM1_32, A_NUM1_64: begin
              idx_v = fn_desc_is_1(awaddr_q[7:0]);
              old_data_v = {{(DATA_WIDTH-32){1'b0}}, reg_num_bytes[idx_v]};
              new_data_v = fn_apply_wstrb(old_data_v, wdata_q, wstrb_q);
              reg_num_bytes[idx_v] <= new_data_v[31:0];
            end

            A_CFG0, A_CFG1_32, A_CFG1_64: begin
              idx_v = fn_desc_is_1(awaddr_q[7:0]);
              old_data_v[0] = reg_wr_mode[idx_v];
              old_data_v[1] = reg_rd_mode[idx_v];
              old_data_v[2] = reg_enable[idx_v];
              new_data_v = fn_apply_wstrb(old_data_v, wdata_q, wstrb_q);
              reg_wr_mode[idx_v] <= new_data_v[0];
              reg_rd_mode[idx_v] <= new_data_v[1];
              reg_enable[idx_v]  <= new_data_v[2];
            end

            default: bresp_q <= AXI_RESP_SLVERR;
          endcase
        end

        bvalid_q <= 1'b1;
        aw_hold  <= 1'b0;
        w_hold   <= 1'b0;
      end

      if (bvalid_q && i_bready) bvalid_q <= 1'b0;

      // read execute
      if (!rvalid_q && i_arvalid) begin
        int unsigned idx_v;
        idx_v = 0;

        arid_q  <= i_arid;
        rresp_q <= AXI_RESP_OKAY;
        rdata_q <= '0;

        if (!fn_addr_high_zero(i_araddr) || !fn_addr_aligned_4(i_araddr)) begin
          rresp_q <= AXI_RESP_SLVERR;
          rdata_q <= '0;
        end else begin
          unique case (i_araddr[7:0])
            A_CONTROL: begin
              rdata_q[0]   <= reg_go;
              rdata_q[1]   <= reg_abort;
              rdata_q[9:2] <= reg_max_burst;
            end

            A_STATUS: begin
              rdata_q[15:0] <= 16'hCAFE;
              rdata_q[16]   <= i_dma_status_done;
              rdata_q[17]   <= i_dma_error_stats_error_trig;
            end

            A_ERROR_ADDR: rdata_q[31:0] <= i_dma_error_addr_error_addr;

            A_ERROR_STATS: begin
              rdata_q[0] <= i_dma_error_stats_error_type;
              rdata_q[1] <= i_dma_error_stats_error_src;
              rdata_q[2] <= i_dma_error_stats_error_trig;
            end

            A_SRC0, A_SRC1_32, A_SRC1_64: begin
              idx_v = fn_desc_is_1(i_araddr[7:0]);
              rdata_q[31:0] <= reg_src_addr[idx_v];
            end

            A_DST0, A_DST1_32, A_DST1_64: begin
              idx_v = fn_desc_is_1(i_araddr[7:0]);
              rdata_q[31:0] <= reg_dst_addr[idx_v];
            end

            A_NUM0, A_NUM1_32, A_NUM1_64: begin
              idx_v = fn_desc_is_1(i_araddr[7:0]);
              rdata_q[31:0] <= reg_num_bytes[idx_v];
            end

            A_CFG0, A_CFG1_32, A_CFG1_64: begin
              idx_v = fn_desc_is_1(i_araddr[7:0]);
              rdata_q[0] <= reg_wr_mode[idx_v];
              rdata_q[1] <= reg_rd_mode[idx_v];
              rdata_q[2] <= reg_enable[idx_v];
            end

            default: begin
              rresp_q <= AXI_RESP_SLVERR;
              rdata_q <= '0;
            end
          endcase
        end

        rvalid_q <= 1'b1;
      end

      if (rvalid_q && i_rready) rvalid_q <= 1'b0;
    end
  end

endmodule