`timescale 1ns / 1ps

// Final classifier stage for the 8x8x64 feature map.
// It accumulates the final-pool write stream into GAP sums while conv_top is
// still running, then runs a 64->10 int8 FC layer when start is asserted.
module gap_fc_logits #(
    parameter string FC_WEIGHT_FILE = "export_cifar/cifar10_int8_pow2_fused/fc_weight_i8.memh",
    parameter string FC_BIAS_FILE   = "export_cifar/cifar10_int8_pow2_fused_bias_i8/fc_bias_i8.memh",
    parameter int POOL_ROWS = 128,
    parameter int POOL_AW = (POOL_ROWS <= 1) ? 1 : $clog2(POOL_ROWS),
    parameter int DATA_DW = 256,
    parameter int CHANNELS = 64,
    parameter int OUT_CLASSES = 10,
    parameter int LANES = 32,
    parameter int FC_SHIFT = 7
)(
    input  logic clk,
    input  logic rst_n,
    input  logic clear,
    input  logic start,

    output logic pool_rd_en,
    output logic [POOL_AW-1:0] pool_rd_addr,
    input  logic [DATA_DW-1:0] pool_rd_data,

    input  logic stream_wr_en,
    input  logic [POOL_AW-1:0] stream_wr_addr,
    input  logic [DATA_DW-1:0] stream_wr_data,

    output logic busy,
    output logic done,

    input  logic dbg_logit_rd_en,
    input  logic [3:0] dbg_logit_rd_addr,
    output logic [7:0] dbg_logit_rd_data,

    output logic pred_valid,
    output logic [3:0] pred_class_id,
    output logic [7:0] pred_logit,
    output logic [(OUT_CLASSES*8)-1:0] logits_flat
);

    typedef enum logic [3:0] {
        S_IDLE,
        S_PREP_FC,
        S_MUL,
        S_ADD32,
        S_ADD16,
        S_ADD8,
        S_ADD4,
        S_ADD2,
        S_ADD1,
        S_WRITE,
        S_DONE
    } state_t;

    state_t state;
    logic signed [31:0] gap_sum [0:CHANNELS-1];
    logic signed [7:0] gap_feat [0:CHANNELS-1];
    logic signed [31:0] fc_acc;
    logic [3:0] class_idx;
    logic signed [7:0] fc_weight [0:(OUT_CLASSES*CHANNELS)-1];
    logic signed [7:0] fc_bias [0:OUT_CLASSES-1];
    logic signed [7:0] logit_q [0:OUT_CLASSES-1];
    logic signed [31:0] prod_stage [0:CHANNELS-1];
    logic signed [31:0] sum32_stage [0:31];
    logic signed [31:0] sum16_stage [0:15];
    logic signed [31:0] sum8_stage [0:7];
    logic signed [31:0] sum4_stage [0:3];
    logic signed [31:0] sum2_stage [0:1];
    logic signed [31:0] sum1_stage;
    logic signed [7:0] current_logit;
    logic [3:0] best_class_id;
    logic signed [7:0] best_logit;

    initial begin
        $readmemh(FC_WEIGHT_FILE, fc_weight);
        $readmemh(FC_BIAS_FILE, fc_bias);
    end

    genvar logit_idx;
    generate
        for (logit_idx = 0; logit_idx < OUT_CLASSES; logit_idx = logit_idx + 1) begin : g_logits_flat
            assign logits_flat[logit_idx*8 +: 8] = logit_q[logit_idx];
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            pool_rd_en <= 1'b0;
            pool_rd_addr <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            fc_acc <= 32'sd0;
            class_idx <= 4'd0;
            sum1_stage <= 32'sd0;
            dbg_logit_rd_data <= '0;
            pred_valid <= 1'b0;
            pred_class_id <= 4'd0;
            pred_logit <= 8'd0;
            current_logit <= 8'sd0;
            best_class_id <= 4'd0;
            best_logit <= -8'sd128;
            for (int i = 0; i < CHANNELS; i = i + 1) begin
                gap_sum[i] <= 32'sd0;
                gap_feat[i] <= 8'sd0;
                prod_stage[i] <= 32'sd0;
            end
            for (int i = 0; i < 32; i = i + 1) begin
                sum32_stage[i] <= 32'sd0;
            end
            for (int i = 0; i < 16; i = i + 1) begin
                sum16_stage[i] <= 32'sd0;
            end
            for (int i = 0; i < 8; i = i + 1) begin
                sum8_stage[i] <= 32'sd0;
            end
            for (int i = 0; i < 4; i = i + 1) begin
                sum4_stage[i] <= 32'sd0;
            end
            for (int i = 0; i < 2; i = i + 1) begin
                sum2_stage[i] <= 32'sd0;
            end
            for (int c = 0; c < OUT_CLASSES; c = c + 1) begin
                logit_q[c] <= 8'sd0;
            end
        end else begin
            pool_rd_en <= 1'b0;
            pool_rd_addr <= '0;
            done <= 1'b0;

            if (dbg_logit_rd_en) begin
                if (dbg_logit_rd_addr < OUT_CLASSES[3:0]) begin
                    dbg_logit_rd_data <= logit_q[dbg_logit_rd_addr];
                end else begin
                    dbg_logit_rd_data <= '0;
                end
            end

            if (clear) begin
                for (int i = 0; i < CHANNELS; i = i + 1) begin
                    gap_sum[i] <= 32'sd0;
                    gap_feat[i] <= 8'sd0;
                end
                for (int c = 0; c < OUT_CLASSES; c = c + 1) begin
                    logit_q[c] <= 8'sd0;
                end
                pred_valid <= 1'b0;
                pred_class_id <= 4'd0;
                pred_logit <= 8'd0;
                current_logit <= 8'sd0;
                best_class_id <= 4'd0;
                best_logit <= -8'sd128;
            end else if (stream_wr_en) begin
                for (int lane = 0; lane < LANES; lane = lane + 1) begin
                    if (stream_wr_addr[0]) begin
                        gap_sum[LANES + lane] <= gap_sum[LANES + lane] + sign_extend_pool_byte(stream_wr_data, lane);
                    end else begin
                        gap_sum[lane] <= gap_sum[lane] + sign_extend_pool_byte(stream_wr_data, lane);
                    end
                end
            end

            unique case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        fc_acc <= 32'sd0;
                        class_idx <= 4'd0;
                        pred_valid <= 1'b0;
                        pred_class_id <= 4'd0;
                        pred_logit <= 8'd0;
                        best_class_id <= 4'd0;
                        best_logit <= -8'sd128;
                        for (int ch = 0; ch < CHANNELS; ch = ch + 1) begin
                            gap_feat[ch] <= sat_i8(gap_sum[ch] >>> 6);
                        end
                        state <= S_PREP_FC;
                    end
                end

                S_PREP_FC: begin
                    fc_acc <= 32'sd0;
                    class_idx <= 4'd0;
                    state <= S_MUL;
                end

                S_MUL: begin
                    for (int lane = 0; lane < CHANNELS; lane = lane + 1) begin
                        prod_stage[lane] <= sext_i8(gap_feat[lane]) *
                                            sext_i8(fc_weight[int'(class_idx) * CHANNELS + lane]);
                    end
                    state <= S_ADD32;
                end

                S_ADD32: begin
                    for (int i = 0; i < 32; i = i + 1) begin
                        sum32_stage[i] <= prod_stage[i*2] + prod_stage[i*2 + 1];
                    end
                    state <= S_ADD16;
                end

                S_ADD16: begin
                    for (int i = 0; i < 16; i = i + 1) begin
                        sum16_stage[i] <= sum32_stage[i*2] + sum32_stage[i*2 + 1];
                    end
                    state <= S_ADD8;
                end

                S_ADD8: begin
                    for (int i = 0; i < 8; i = i + 1) begin
                        sum8_stage[i] <= sum16_stage[i*2] + sum16_stage[i*2 + 1];
                    end
                    state <= S_ADD4;
                end

                S_ADD4: begin
                    for (int i = 0; i < 4; i = i + 1) begin
                        sum4_stage[i] <= sum8_stage[i*2] + sum8_stage[i*2 + 1];
                    end
                    state <= S_ADD2;
                end

                S_ADD2: begin
                    for (int i = 0; i < 2; i = i + 1) begin
                        sum2_stage[i] <= sum4_stage[i*2] + sum4_stage[i*2 + 1];
                    end
                    state <= S_ADD1;
                end

                S_ADD1: begin
                    sum1_stage <= sum2_stage[0] + sum2_stage[1];
                    state <= S_WRITE;
                end

                S_WRITE: begin
                    current_logit = postproc_fc(sum1_stage, fc_bias[class_idx]);
                    logit_q[class_idx] <= current_logit;
                    if ((class_idx == 4'd0) || (current_logit > best_logit)) begin
                        best_logit <= current_logit;
                        best_class_id <= class_idx;
                    end
                    if (class_idx == OUT_CLASSES[3:0] - 4'd1) begin
                        pred_valid <= 1'b1;
                        if (current_logit > best_logit) begin
                            pred_class_id <= class_idx;
                            pred_logit <= current_logit;
                        end else begin
                            pred_class_id <= best_class_id;
                            pred_logit <= best_logit;
                        end
                        state <= S_DONE;
                    end else begin
                        class_idx <= class_idx + 4'd1;
                        state <= S_MUL;
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

    function automatic logic signed [7:0] sign_extend_pool_byte(
        input logic [DATA_DW-1:0] word,
        input int lane
    );
        begin
            sign_extend_pool_byte = $signed(word[(LANES-1-lane)*8 +: 8]);
        end
    endfunction

    function automatic logic signed [31:0] sext_i8(input logic signed [7:0] value);
        begin
            sext_i8 = {{24{value[7]}}, value};
        end
    endfunction

    function automatic logic signed [7:0] postproc_fc(
        input logic signed [31:0] acc,
        input logic signed [7:0] bias
    );
        logic signed [31:0] shifted;
        logic signed [31:0] biased;
        begin
            shifted = acc >>> FC_SHIFT;
            biased = shifted + {{24{bias[7]}}, bias};
            postproc_fc = sat_i8(biased);
        end
    endfunction

    function automatic logic signed [7:0] sat_i8(input logic signed [31:0] vin);
        begin
            if (vin > 32'sd127) begin
                sat_i8 = 8'sd127;
            end else if (vin < -32'sd128) begin
                sat_i8 = -8'sd128;
            end else begin
                sat_i8 = vin[7:0];
            end
        end
    endfunction

endmodule
