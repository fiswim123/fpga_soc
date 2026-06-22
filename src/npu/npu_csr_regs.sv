`timescale 1ns / 1ps

// Minimal CSR block for the im2col DMAC path.
// TB/software writes these registers, then the scheduler uses them to generate
// row_base/k_idx requests for one 40-row tile.
module npu_csr_regs #(
    parameter int AW = 8,
    parameter int DW = 32
)(
    input  logic clk,
    input  logic rst_n,

    input  logic csr_wr_en,
    input  logic csr_rd_en,
    input  logic [AW-1:0] csr_addr,
    input  logic [DW-1:0] csr_wdata,
    output logic [DW-1:0] csr_rdata,

    input  logic dmac_busy,
    input  logic dmac_done,
    input  logic result_valid,
    input  logic [3:0] result_class_id,
    input  logic [7:0] result_logit,

    output logic start_pulse,
    output logic layer_sel,
    output logic [5:0] cfg_in_w,
    output logic [5:0] cfg_in_h,
    output logic [5:0] cfg_in_ch,
    output logic [2:0] cfg_kernel,
    output logic [2:0] cfg_pad,
    output logic [9:0] cfg_row_base,
    output logic [9:0] cfg_k_len
);

    localparam logic [AW-1:0] REG_CTRL     = 8'h00;
    localparam logic [AW-1:0] REG_STATUS   = 8'h04;
    localparam logic [AW-1:0] REG_SHAPE0   = 8'h08;
    localparam logic [AW-1:0] REG_SHAPE1   = 8'h0c;
    localparam logic [AW-1:0] REG_TILE     = 8'h10;
    localparam logic [AW-1:0] REG_PRED     = 8'h20;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_pulse <= 1'b0;
            layer_sel <= 1'b0;
            cfg_in_w <= 6'd32;
            cfg_in_h <= 6'd32;
            cfg_in_ch <= 6'd3;
            cfg_kernel <= 3'd5;
            cfg_pad <= 3'd2;
            cfg_row_base <= 10'd0;
            cfg_k_len <= 10'd75;
        end else begin
            start_pulse <= 1'b0;
            if (csr_wr_en) begin
                unique case (csr_addr)
                    REG_CTRL: begin
                        start_pulse <= csr_wdata[0];
                        layer_sel <= csr_wdata[1];
                    end
                    REG_SHAPE0: begin
                        cfg_in_w <= csr_wdata[5:0];
                        cfg_in_h <= csr_wdata[13:8];
                        cfg_in_ch <= csr_wdata[21:16];
                    end
                    REG_SHAPE1: begin
                        cfg_kernel <= csr_wdata[2:0];
                        cfg_pad <= csr_wdata[10:8];
                        cfg_k_len <= csr_wdata[25:16];
                    end
                    REG_TILE: begin
                        cfg_row_base <= csr_wdata[9:0];
                    end
                    default: begin
                    end
                endcase
            end
        end
    end

    always_comb begin
        csr_rdata = '0;
        if (csr_rd_en) begin
            unique case (csr_addr)
                REG_CTRL: begin
                    csr_rdata[1] = layer_sel;
                end
                REG_STATUS: begin
                    csr_rdata[0] = dmac_busy;
                    csr_rdata[1] = dmac_done;
                end
                REG_SHAPE0: begin
                    csr_rdata[5:0] = cfg_in_w;
                    csr_rdata[13:8] = cfg_in_h;
                    csr_rdata[21:16] = cfg_in_ch;
                end
                REG_SHAPE1: begin
                    csr_rdata[2:0] = cfg_kernel;
                    csr_rdata[10:8] = cfg_pad;
                    csr_rdata[25:16] = cfg_k_len;
                end
                REG_TILE: begin
                    csr_rdata[9:0] = cfg_row_base;
                end
                REG_PRED: begin
                    csr_rdata[0] = result_valid;
                    csr_rdata[11:8] = result_class_id;
                    csr_rdata[23:16] = result_logit;
                    csr_rdata[31:24] = {8{result_logit[7]}};
                end
                default: csr_rdata = '0;
            endcase
        end
    end

endmodule
