`timescale 1ns / 1ps

// True 40x32 MAC array shell: 10x8 instances of mm_systolic_4x4.
// One accepted input beat feeds 40 A values and one 32-channel weight row.
// This first version targets conv1 DOT_K=75 and emits one 40x32 int8 tile.
module mac_array_40x32_stream #(
    parameter string W_FILE    = "conv1.dat",
    parameter string W2_FILE   = "conv2.dat",
    parameter string BIAS_FILE = "bias1.dat",
    parameter string BIAS2_FILE = "bias2.dat",
    parameter int MAX_DOT_K = 800,
    parameter int L1_DOT_K = 75,
    parameter int L2_DOT_K = 800,
    parameter int TILE_ROWS = 40,
    parameter int OUT_COLS = 32,
    parameter int L2_OUT_COLS = 64,
    parameter int SUB_M = 4,
    parameter int ROW_GROUPS = TILE_ROWS / SUB_M,
    parameter int COL_GROUPS = OUT_COLS / SUB_M,
    parameter int W_AW = 10,
    parameter int W_DW = OUT_COLS * 8,
    parameter int W2_DW = L2_OUT_COLS * 8,
    parameter int W_ADDR = MAX_DOT_K,
    parameter int OUT_ROWS = 1024,
    parameter int OUT_DW = OUT_COLS * 8,
    parameter int OUT_AW = (OUT_ROWS <= 1) ? 1 : $clog2(OUT_ROWS)
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    input  logic [OUT_AW-1:0] tile_base_row,
    input  logic layer_sel,
    input  logic out_pass,
    input  logic [15:0] active_dot_k,
    input  logic [15:0] active_out_rows,
    input  logic [1:0] result_addr_stride,
    input  logic [1:0] result_addr_offset,
    input  logic signed_mode,
    input  logic [4:0] out_shift,
    input  logic relu_en,

    input  logic a_col_valid,
    input  logic [TILE_ROWS*8-1:0] a_col_320b,
    output logic a_col_ready,

    output logic tile_valid,
    output logic [(ROW_GROUPS*COL_GROUPS*SUB_M*SUB_M*8)-1:0] tile_data,

    output logic result_wr_en,
    output logic [OUT_AW-1:0] result_wr_addr,
    output logic [OUT_DW-1:0] result_wr_data,
    output logic result_busy,
    output logic result_done
);

    localparam int SA_RES_DW = SUB_M * SUB_M * 8;
    localparam int TILE_DW = ROW_GROUPS * COL_GROUPS * SA_RES_DW;

    typedef enum logic [1:0] {
        S_IDLE,
        S_FLUSH,
        S_FEED,
        S_WAIT
    } state_t;

    state_t state;
    logic flush;
    logic [W_AW:0] feed_count;
    logic [3:0] wait_count;
    logic sa_valid;

    logic signed [7:0] bias_mem [0:OUT_COLS-1];
    logic signed [7:0] bias2_mem [0:L2_OUT_COLS-1];
    logic signed [7:0] a_lane [0:TILE_ROWS-1];
    logic signed [7:0] w_lane [0:OUT_COLS-1];
    logic [31:0] sa_row [0:ROW_GROUPS-1][0:COL_GROUPS-1];
    logic [31:0] sa_col [0:ROW_GROUPS-1][0:COL_GROUPS-1];
    logic [SUB_M*8-1:0] sa_bias [0:COL_GROUPS-1];
    logic [SA_RES_DW-1:0] sa_res [0:ROW_GROUPS-1][0:COL_GROUPS-1];
    logic [TILE_DW-1:0] result_tile_buf;
    logic [OUT_AW-1:0] result_base_row;
    logic [15:0] result_out_rows;
    logic [1:0] result_stride;
    logic [1:0] result_offset;
    logic [5:0] result_wr_row;

    assign a_col_ready = (state == S_FEED);
    assign sa_valid = a_col_valid && a_col_ready;

    (* ram_style = "block" *) logic [W_DW-1:0] weight_buf [0:L1_DOT_K-1];
    (* ram_style = "block" *) logic [W2_DW-1:0] weight2_buf [0:L2_DOT_K-1];

    initial begin
        $readmemh(BIAS_FILE, bias_mem);
        $readmemh(BIAS2_FILE, bias2_mem);
        $readmemh(W_FILE, weight_buf);
        $readmemh(W2_FILE, weight2_buf);
    end

    always_comb begin
        for (int i = 0; i < TILE_ROWS; i = i + 1) begin
            a_lane[i] = $signed(a_col_320b[TILE_ROWS*8-1 - i*8 -: 8]);
        end
        for (int j = 0; j < OUT_COLS; j = j + 1) begin
            if (layer_sel) begin
                w_lane[j] = $signed(weight2_buf[feed_count][W2_DW-1 - (out_pass*OUT_COLS+j)*8 -: 8]);
            end else begin
                w_lane[j] = $signed(weight_buf[feed_count][W_DW-1 - j*8 -: 8]);
            end
        end
        for (int cg = 0; cg < COL_GROUPS; cg = cg + 1) begin
            if (layer_sel) begin
                sa_bias[cg] = {
                    bias2_mem[out_pass*OUT_COLS+cg*SUB_M+3],
                    bias2_mem[out_pass*OUT_COLS+cg*SUB_M+2],
                    bias2_mem[out_pass*OUT_COLS+cg*SUB_M+1],
                    bias2_mem[out_pass*OUT_COLS+cg*SUB_M+0]
                };
            end else begin
                sa_bias[cg] = {
                    bias_mem[cg*SUB_M+3],
                    bias_mem[cg*SUB_M+2],
                    bias_mem[cg*SUB_M+1],
                    bias_mem[cg*SUB_M+0]
                };
            end
        end
        for (int rg = 0; rg < ROW_GROUPS; rg = rg + 1) begin
            for (int cg = 0; cg < COL_GROUPS; cg = cg + 1) begin
                sa_row[rg][cg] = {
                    a_lane[rg*SUB_M+0],
                    a_lane[rg*SUB_M+1],
                    a_lane[rg*SUB_M+2],
                    a_lane[rg*SUB_M+3]
                };
                sa_col[rg][cg] = {
                    w_lane[cg*SUB_M+0],
                    w_lane[cg*SUB_M+1],
                    w_lane[cg*SUB_M+2],
                    w_lane[cg*SUB_M+3]
                };
            end
        end
    end

    genvar gi, gj;
    generate
        for (gi = 0; gi < ROW_GROUPS; gi = gi + 1) begin : rg_gen
            for (gj = 0; gj < COL_GROUPS; gj = gj + 1) begin : cg_gen
                mm_systolic_4x4 #(
                    .DOT_K(MAX_DOT_K)
                ) u_sa (
                    .clk(clk),
                    .rst_n(rst_n),
                    .signed_mode(signed_mode),
                    .row_bar(sa_row[gi][gj]),
                    .col_bar(sa_col[gi][gj]),
                    .bar_valid(sa_valid),
                    .dot_k(active_dot_k),
                    .out_shift(out_shift),
                    .bias_vec(sa_bias[gj]),
                    .relu_en(relu_en),
                    .res(sa_res[gi][gj]),
                    .res_valid(),
                    .flush(flush),
                    .add_mode(1'b0),
                    .add_compute_valid(1'b0)
                );
            end
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            flush <= 1'b0;
            feed_count <= '0;
            wait_count <= '0;
            tile_valid <= 1'b0;
            tile_data <= '0;
            result_wr_en <= 1'b0;
            result_wr_addr <= '0;
            result_wr_data <= '0;
            result_busy <= 1'b0;
            result_done <= 1'b0;
            result_tile_buf <= '0;
            result_base_row <= '0;
            result_out_rows <= '0;
            result_stride <= '0;
            result_offset <= '0;
            result_wr_row <= '0;
        end else begin
            flush <= 1'b0;
            tile_valid <= 1'b0;
            result_wr_en <= 1'b0;
            result_done <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    if (start) begin
                        flush <= 1'b1;
                        feed_count <= '0;
                        wait_count <= '0;
                        state <= S_FLUSH;
                    end
                end

                S_FLUSH: begin
                    state <= S_FEED;
                end

                S_FEED: begin
                    if (a_col_valid && a_col_ready) begin
                        feed_count <= feed_count + 1'b1;
                        if (feed_count == W_AW'(active_dot_k - 16'd1)) begin
                            wait_count <= '0;
                            state <= S_WAIT;
                        end
                    end
                end

                S_WAIT: begin
                    if (wait_count == 4'd8) begin
                        for (int rg = 0; rg < ROW_GROUPS; rg = rg + 1) begin
                            for (int cg = 0; cg < COL_GROUPS; cg = cg + 1) begin
                                tile_data[((rg*COL_GROUPS+cg)*SA_RES_DW) +: SA_RES_DW] <= sa_res[rg][cg];
                                result_tile_buf[((rg*COL_GROUPS+cg)*SA_RES_DW) +: SA_RES_DW] <= sa_res[rg][cg];
                            end
                        end
                        tile_valid <= 1'b1;
                        result_base_row <= tile_base_row;
                        result_out_rows <= active_out_rows;
                        result_stride <= result_addr_stride;
                        result_offset <= result_addr_offset;
                        result_wr_row <= 6'd0;
                        result_busy <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase

            if (result_busy) begin
                if (result_global_row() < result_out_rows) begin
                    result_wr_en <= 1'b1;
                    result_wr_addr <= OUT_AW'((result_base_row + OUT_AW'(result_wr_row)) * result_stride + result_offset);
                    result_wr_data <= result_row_data();
                end

                if (result_wr_row == TILE_ROWS[5:0] - 6'd1) begin
                    result_busy <= 1'b0;
                    result_done <= 1'b1;
                end else begin
                    result_wr_row <= result_wr_row + 6'd1;
                end
            end
        end
    end

    function automatic int result_global_row();
        begin
            result_global_row = result_base_row + result_wr_row;
        end
    endfunction

    function automatic logic [OUT_DW-1:0] result_row_data();
        int rg;
        int rr;
        int bit_base;
        begin
            rg = result_wr_row / SUB_M;
            rr = result_wr_row % SUB_M;
            for (int cg = 0; cg < COL_GROUPS; cg = cg + 1) begin
                bit_base = ((rg * COL_GROUPS + cg) * SA_RES_DW) + (rr * SUB_M * 8);
                for (int cc = 0; cc < SUB_M; cc = cc + 1) begin
                    result_row_data[(OUT_COLS-1-(cg*SUB_M+cc))*8 +: 8] =
                        result_tile_buf[bit_base + cc*8 +: 8];
                end
            end
        end
    endfunction

endmodule
