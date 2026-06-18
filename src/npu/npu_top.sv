`timescale 1ns / 1ps

module npu_top #(
    parameter string IMAGE_DATA_FILE = "image_data.dat",
    parameter string CONV1_FILE      = "conv1.dat",
    parameter string CONV2_FILE      = "conv2.dat",
    parameter string BIAS1_FILE      = "bias1.dat",
    parameter string BIAS2_FILE      = "bias2.dat",
    parameter string FC_WEIGHT_FILE  = "export_cifar/cifar10_int8_pow2_fused/fc_weight_i8.memh",
    parameter string FC_BIAS_FILE    = "export_cifar/cifar10_int8_pow2_fused_bias_i8/fc_bias_i8.memh",
    parameter int IMG_PIXELS = 1024,
    parameter int SA_ROWS = 5600,
    parameter int TILE_ROWS = 40,
    parameter int SA_DW = TILE_ROWS * 8,
    parameter int SA_AW = (SA_ROWS <= 1) ? 1 : $clog2(SA_ROWS),
    parameter int OUT_ROWS = 1024,
    parameter int OUT_COLS = 32,
    parameter int OUT_DW = OUT_COLS * 8,
    parameter int OUT_AW = (OUT_ROWS <= 1) ? 1 : $clog2(OUT_ROWS),
    parameter int POOL_ROWS = 256,
    parameter int POOL_AW = (POOL_ROWS <= 1) ? 1 : $clog2(POOL_ROWS)
)(
    input  logic clk,
    input  logic rst_n,

    input  logic csr_wr_en,
    input  logic csr_rd_en,
    input  logic [7:0] csr_addr,
    input  logic [31:0] csr_wdata,
    output logic [31:0] csr_rdata,

    output logic busy,
    output logic done,

    input  logic dbg_sa_rd_en,
    input  logic [SA_AW-1:0] dbg_sa_rd_addr,
    output logic [SA_DW-1:0] dbg_sa_rd_data,

    input  logic dbg_result_rd_en,
    input  logic [OUT_AW-1:0] dbg_result_rd_addr,
    output logic [OUT_DW-1:0] dbg_result_rd_data,

    input  logic dbg_pool_rd_en,
    input  logic [POOL_AW-1:0] dbg_pool_rd_addr,
    output logic [OUT_DW-1:0] dbg_pool_rd_data,

    input  logic dbg_logit_rd_en,
    input  logic [3:0] dbg_logit_rd_addr,
    output logic [7:0] dbg_logit_rd_data,

    output logic pred_valid,
    output logic [3:0] pred_class_id,
    output logic [7:0] pred_logit,

    output logic mac_dbg_tile_valid,
    output logic [(10*8*4*4*8)-1:0] mac_dbg_tile_data
);

    localparam logic [7:0] REG_CTRL = 8'h00;

    typedef enum logic [1:0] {
        T_IDLE,
        T_WAIT_CONV,
        T_WAIT_FC
    } top_state_t;

    top_state_t top_state;
    logic conv_busy;
    logic conv_done;
    logic fc_start;
    logic fc_busy;
    logic fc_done;
    logic fc_clear;
    logic top_done_pulse;
    logic conv_dbg_pool_rd_en;
    logic [POOL_AW-1:0] conv_dbg_pool_rd_addr;
    logic [OUT_DW-1:0] conv_dbg_pool_rd_data;
    logic fc_pool_rd_en;
    logic [POOL_AW-1:0] fc_pool_rd_addr;
    logic final_pool_wr_en;
    logic [POOL_AW-1:0] final_pool_wr_addr;
    logic [OUT_DW-1:0] final_pool_wr_data;
    logic fc_pred_valid;
    logic [3:0] fc_pred_class_id;
    logic [7:0] fc_pred_logit;
    logic [79:0] fc_logits_flat;

    assign busy = conv_busy || fc_busy || (top_state != T_IDLE);
    assign done = top_done_pulse;
    assign pred_valid = fc_pred_valid;
    assign pred_class_id = fc_pred_class_id;
    assign pred_logit = fc_pred_logit;
    assign fc_clear = csr_wr_en && (csr_addr == REG_CTRL) && csr_wdata[0];
    assign conv_dbg_pool_rd_en = dbg_pool_rd_en;
    assign conv_dbg_pool_rd_addr = dbg_pool_rd_addr;
    assign dbg_pool_rd_data = conv_dbg_pool_rd_data;

    conv_top #(
        .IMAGE_DATA_FILE(IMAGE_DATA_FILE),
        .CONV1_FILE(CONV1_FILE),
        .CONV2_FILE(CONV2_FILE),
        .BIAS1_FILE(BIAS1_FILE),
        .BIAS2_FILE(BIAS2_FILE),
        .IMG_PIXELS(IMG_PIXELS),
        .SA_ROWS(SA_ROWS),
        .TILE_ROWS(TILE_ROWS),
        .SA_DW(SA_DW),
        .SA_AW(SA_AW),
        .OUT_ROWS(OUT_ROWS),
        .OUT_COLS(OUT_COLS),
        .OUT_DW(OUT_DW),
        .OUT_AW(OUT_AW),
        .POOL_ROWS(POOL_ROWS),
        .POOL_AW(POOL_AW)
    ) u_conv (
        .clk(clk),
        .rst_n(rst_n),
        .csr_wr_en(csr_wr_en),
        .csr_rd_en(csr_rd_en),
        .csr_addr(csr_addr),
        .csr_wdata(csr_wdata),
        .csr_rdata(csr_rdata),
        .busy(conv_busy),
        .done(conv_done),
        .dbg_sa_rd_en(dbg_sa_rd_en),
        .dbg_sa_rd_addr(dbg_sa_rd_addr),
        .dbg_sa_rd_data(dbg_sa_rd_data),
        .dbg_result_rd_en(dbg_result_rd_en),
        .dbg_result_rd_addr(dbg_result_rd_addr),
        .dbg_result_rd_data(dbg_result_rd_data),
        .dbg_pool_rd_en(conv_dbg_pool_rd_en),
        .dbg_pool_rd_addr(conv_dbg_pool_rd_addr),
        .dbg_pool_rd_data(conv_dbg_pool_rd_data),
        .final_pool_wr_en(final_pool_wr_en),
        .final_pool_wr_addr(final_pool_wr_addr),
        .final_pool_wr_data(final_pool_wr_data),
        .result_valid(fc_pred_valid),
        .result_class_id(fc_pred_class_id),
        .result_logit(fc_pred_logit),
        .result_logits_flat(fc_logits_flat),
        .mac_dbg_tile_valid(mac_dbg_tile_valid),
        .mac_dbg_tile_data(mac_dbg_tile_data)
    );

    gap_fc_logits #(
        .FC_WEIGHT_FILE(FC_WEIGHT_FILE),
        .FC_BIAS_FILE(FC_BIAS_FILE),
        .POOL_ROWS(128),
        .POOL_AW(POOL_AW),
        .DATA_DW(OUT_DW),
        .CHANNELS(64),
        .OUT_CLASSES(10),
        .LANES(32),
        .FC_SHIFT(7)
    ) u_fc (
        .clk(clk),
        .rst_n(rst_n),
        .clear(fc_clear),
        .start(fc_start),
        .pool_rd_en(fc_pool_rd_en),
        .pool_rd_addr(fc_pool_rd_addr),
        .pool_rd_data(conv_dbg_pool_rd_data),
        .stream_wr_en(final_pool_wr_en),
        .stream_wr_addr(final_pool_wr_addr),
        .stream_wr_data(final_pool_wr_data),
        .busy(fc_busy),
        .done(fc_done),
        .dbg_logit_rd_en(dbg_logit_rd_en),
        .dbg_logit_rd_addr(dbg_logit_rd_addr),
        .dbg_logit_rd_data(dbg_logit_rd_data),
        .pred_valid(fc_pred_valid),
        .pred_class_id(fc_pred_class_id),
        .pred_logit(fc_pred_logit),
        .logits_flat(fc_logits_flat)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            top_state <= T_IDLE;
            fc_start <= 1'b0;
            top_done_pulse <= 1'b0;
        end else begin
            fc_start <= 1'b0;
            top_done_pulse <= 1'b0;

            unique case (top_state)
                T_IDLE: begin
                    if (csr_wr_en && (csr_addr == REG_CTRL) && csr_wdata[0]) begin
                        top_state <= T_WAIT_CONV;
                    end
                end

                T_WAIT_CONV: begin
                    if (conv_done) begin
                        fc_start <= 1'b1;
                        top_state <= T_WAIT_FC;
                    end
                end

                T_WAIT_FC: begin
                    if (fc_done) begin
                        top_done_pulse <= 1'b1;
                        top_state <= T_IDLE;
                    end
                end

                default: top_state <= T_IDLE;
            endcase
        end
    end

endmodule
