`timescale 1ns / 1ps

// Schedules one im2col tile for the 40-row SA input.
// After start, it issues k_idx=0..k_len-1. Each accepted request returns one
// 320-bit A column from dmac_im2col_stream.
module dmac_tile_scheduler #(
    parameter int LANE_NUM = 40
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    input  logic [9:0] cfg_row_base,
    input  logic [9:0] cfg_k_len,

    output logic dmac_req_valid,
    input  logic dmac_req_ready,
    output logic [9:0] dmac_row_base,
    output logic [9:0] dmac_k_idx,

    input  logic dmac_out_valid,
    input  logic [LANE_NUM*8-1:0] dmac_a_col,

    output logic out_valid,
    output logic [LANE_NUM*8-1:0] a_col_320b,
    output logic [9:0] out_k_idx,
    output logic busy,
    output logic done
);

    typedef enum logic [1:0] {
        S_IDLE,
        S_RUN,
        S_DONE
    } state_t;

    state_t state;
    logic [9:0] issue_k;
    logic [9:0] rsp_k;

    assign dmac_row_base = cfg_row_base;
    assign dmac_k_idx = issue_k;
    assign dmac_req_valid = (state == S_RUN) && (issue_k < cfg_k_len);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            issue_k <= 10'd0;
            rsp_k <= 10'd0;
            out_valid <= 1'b0;
            a_col_320b <= '0;
            out_k_idx <= 10'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            done <= 1'b0;

            if (dmac_out_valid) begin
                out_valid <= 1'b1;
                a_col_320b <= dmac_a_col;
                out_k_idx <= rsp_k;
                rsp_k <= rsp_k + 10'd1;
            end

            unique case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        issue_k <= 10'd0;
                        rsp_k <= 10'd0;
                        state <= S_RUN;
                    end
                end

                S_RUN: begin
                    if (dmac_req_valid && dmac_req_ready) begin
                        issue_k <= issue_k + 10'd1;
                    end
                    if ((rsp_k == cfg_k_len) && (issue_k == cfg_k_len)) begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
