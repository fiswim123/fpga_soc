`timescale 1ns / 1ps

// CSR-configurable DMAC frontend for the 40x32 systolic array A side.
module npu_dmac_frontend #(
    parameter string IMAGE_DATA_FILE = "image_data.dat",
    parameter int LANE_NUM = 40
)(
    input  logic clk,
    input  logic rst_n,

    input  logic csr_wr_en,
    input  logic csr_rd_en,
    input  logic [7:0] csr_addr,
    input  logic [31:0] csr_wdata,
    output logic [31:0] csr_rdata,

    input  logic pool_wr_en,
    input  logic [7:0] pool_wr_pixel,
    input  logic [2:0] pool_wr_cg,
    input  logic [31:0] pool_wr_data,

    output logic a_col_valid,
    output logic [LANE_NUM*8-1:0] a_col_320b,
    output logic [9:0] a_col_k_idx,
    output logic busy,
    output logic done
);

    logic start_pulse;
    logic layer_sel;
    logic [5:0] cfg_in_w;
    logic [5:0] cfg_in_h;
    logic [5:0] cfg_in_ch;
    logic [2:0] cfg_kernel;
    logic [2:0] cfg_pad;
    logic [9:0] cfg_row_base;
    logic [9:0] cfg_k_len;

    logic dmac_req_valid;
    logic dmac_req_ready;
    logic [9:0] dmac_row_base;
    logic [9:0] dmac_k_idx;
    logic dmac_out_valid;
    logic [LANE_NUM*8-1:0] dmac_a_col;

    npu_csr_regs u_csr (
        .clk(clk),
        .rst_n(rst_n),
        .csr_wr_en(csr_wr_en),
        .csr_rd_en(csr_rd_en),
        .csr_addr(csr_addr),
        .csr_wdata(csr_wdata),
        .csr_rdata(csr_rdata),
        .dmac_busy(busy),
        .dmac_done(done),
        .result_valid(1'b0),
        .result_class_id(4'd0),
        .result_logit(8'd0),
        .result_logits_flat(80'd0),
        .start_pulse(start_pulse),
        .layer_sel(layer_sel),
        .cfg_in_w(cfg_in_w),
        .cfg_in_h(cfg_in_h),
        .cfg_in_ch(cfg_in_ch),
        .cfg_kernel(cfg_kernel),
        .cfg_pad(cfg_pad),
        .cfg_row_base(cfg_row_base),
        .cfg_k_len(cfg_k_len)
    );

    dmac_tile_scheduler #(
        .LANE_NUM(LANE_NUM)
    ) u_sched (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_pulse),
        .cfg_row_base(cfg_row_base),
        .cfg_k_len(cfg_k_len),
        .dmac_req_valid(dmac_req_valid),
        .dmac_req_ready(dmac_req_ready),
        .dmac_row_base(dmac_row_base),
        .dmac_k_idx(dmac_k_idx),
        .dmac_out_valid(dmac_out_valid),
        .dmac_a_col(dmac_a_col),
        .out_valid(a_col_valid),
        .a_col_320b(a_col_320b),
        .out_k_idx(a_col_k_idx),
        .busy(busy),
        .done(done)
    );

    dmac_im2col_stream #(
        .IMAGE_DATA_FILE(IMAGE_DATA_FILE),
        .LANE_NUM(LANE_NUM)
    ) u_im2col (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(dmac_req_valid),
        .req_ready(dmac_req_ready),
        .layer_sel(layer_sel),
        .cfg_in_w(cfg_in_w),
        .cfg_in_h(cfg_in_h),
        .cfg_in_ch(cfg_in_ch),
        .cfg_kernel(cfg_kernel),
        .cfg_pad(cfg_pad),
        .row_base(dmac_row_base),
        .k_idx(dmac_k_idx),
        .pool_wr_en(pool_wr_en),
        .pool_wr_pixel(pool_wr_pixel),
        .pool_wr_cg(pool_wr_cg),
        .pool_wr_data(pool_wr_data),
        .out_valid(dmac_out_valid),
        .a_col_320b(dmac_a_col)
    );

endmodule
