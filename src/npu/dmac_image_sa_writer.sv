`timescale 1ns / 1ps

// DMAC stage that materializes the first-layer im2col stream into image_sa RAM.
// Output layout matches image_sa.dat:
//   address = tile_idx * K_LEN + k_idx
//   data[319:312] = A[row_base + 0][k_idx]
//   data[7:0]     = A[row_base + 39][k_idx]
module dmac_image_sa_writer #(
    parameter string IMAGE_DATA_FILE = "image_data.dat",
    parameter int TILE_ROWS = 40,
    parameter int L1_IMG_ROWS = 1024,
    parameter int L1_K_LEN    = 75,
    parameter int L1_IMG_W    = 32,
    parameter int L1_IMG_H    = 32,
    parameter int L1_IMG_CH   = 3,
    parameter int L1_KERNEL   = 5,
    parameter int L1_PAD      = 2,
    parameter int L2_IMG_ROWS = 256,
    parameter int L2_K_LEN    = 800,
    parameter int L2_IMG_W    = 16,
    parameter int L2_IMG_H    = 16,
    parameter int L2_IMG_CH   = 32,
    parameter int L2_KERNEL   = 5,
    parameter int L2_PAD      = 2,
    parameter int POOL_DW     = 256,
    parameter int SA_ROWS     = ((L2_IMG_ROWS + TILE_ROWS - 1) / TILE_ROWS) * L2_K_LEN,
    parameter int SA_AW     = (SA_ROWS <= 1) ? 1 : $clog2(SA_ROWS)
)(
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic layer_sel,

    input  logic pool_wr_en,
    input  logic [7:0] pool_wr_pixel,
    input  logic [POOL_DW-1:0] pool_wr_data,

    output logic ram_wr,
    output logic [SA_AW-1:0] ram_waddr,
    output logic [TILE_ROWS*8-1:0] ram_wdata,

    output logic busy,
    output logic done
);

    typedef enum logic [1:0] {
        S_IDLE,
        S_RUN,
        S_DRAIN,
        S_DONE
    } state_t;

    state_t state;
    logic [SA_AW-1:0] issue_addr;
    logic [SA_AW-1:0] issue_addr_d;
    logic issue_valid_d;
    logic req_valid;
    logic req_ready;
    logic out_valid;
    logic [TILE_ROWS*8-1:0] a_col_lsb;
    logic active_layer_sel;
    logic [9:0] active_img_rows;
    logic [9:0] active_k_len;
    logic [5:0] active_img_w;
    logic [5:0] active_img_h;
    logic [5:0] active_img_ch;
    logic [2:0] active_kernel;
    logic [2:0] active_pad;
    logic [SA_AW-1:0] active_sa_rows;
    logic [9:0] row_base;
    logic [9:0] k_idx;

    assign row_base = 10'((issue_addr / active_k_len) * TILE_ROWS);
    assign k_idx = 10'(issue_addr % active_k_len);
    assign req_valid = (state == S_RUN) && (issue_addr < active_sa_rows);

    dmac_im2col_stream #(
        .IMAGE_DATA_FILE(IMAGE_DATA_FILE),
        .LANE_NUM(TILE_ROWS)
    ) u_im2col (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .layer_sel(active_layer_sel),
        .cfg_in_w(active_img_w),
        .cfg_in_h(active_img_h),
        .cfg_in_ch(active_img_ch),
        .cfg_kernel(active_kernel),
        .cfg_pad(active_pad),
        .row_base(row_base),
        .k_idx(k_idx),
        .pool_wr_en(pool_wr_en),
        .pool_wr_pixel(pool_wr_pixel),
        .pool_wr_data(pool_wr_data),
        .out_valid(out_valid),
        .a_col_320b(a_col_lsb)
    );

    function automatic logic [TILE_ROWS*8-1:0] pack_image_sa(
        input logic [TILE_ROWS*8-1:0] lane_lsb
    );
        begin
            for (int lane = 0; lane < TILE_ROWS; lane = lane + 1) begin
                pack_image_sa[TILE_ROWS*8-1 - lane*8 -: 8] = lane_lsb[lane*8 +: 8];
            end
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            issue_addr <= '0;
            issue_addr_d <= '0;
            issue_valid_d <= 1'b0;
            ram_wr <= 1'b0;
            ram_waddr <= '0;
            ram_wdata <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            active_layer_sel <= 1'b0;
            active_img_rows <= 10'(L1_IMG_ROWS);
            active_k_len <= 10'(L1_K_LEN);
            active_img_w <= 6'(L1_IMG_W);
            active_img_h <= 6'(L1_IMG_H);
            active_img_ch <= 6'(L1_IMG_CH);
            active_kernel <= 3'(L1_KERNEL);
            active_pad <= 3'(L1_PAD);
            active_sa_rows <= SA_AW'(((L1_IMG_ROWS + TILE_ROWS - 1) / TILE_ROWS) * L1_K_LEN);
        end else begin
            ram_wr <= 1'b0;
            done <= 1'b0;
            issue_valid_d <= 1'b0;

            if (req_valid && req_ready) begin
                issue_addr_d <= issue_addr;
                issue_valid_d <= 1'b1;
            end

            if (out_valid && issue_valid_d) begin
                ram_wr <= 1'b1;
                ram_waddr <= issue_addr_d;
                ram_wdata <= pack_image_sa(a_col_lsb);
            end

            unique case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        issue_addr <= '0;
                        issue_addr_d <= '0;
                        issue_valid_d <= 1'b0;
                        active_layer_sel <= layer_sel;
                        if (layer_sel) begin
                            active_img_rows <= 10'(L2_IMG_ROWS);
                            active_k_len <= 10'(L2_K_LEN);
                            active_img_w <= 6'(L2_IMG_W);
                            active_img_h <= 6'(L2_IMG_H);
                            active_img_ch <= 6'(L2_IMG_CH);
                            active_kernel <= 3'(L2_KERNEL);
                            active_pad <= 3'(L2_PAD);
                            active_sa_rows <= SA_AW'(((L2_IMG_ROWS + TILE_ROWS - 1) / TILE_ROWS) * L2_K_LEN);
                        end else begin
                            active_img_rows <= 10'(L1_IMG_ROWS);
                            active_k_len <= 10'(L1_K_LEN);
                            active_img_w <= 6'(L1_IMG_W);
                            active_img_h <= 6'(L1_IMG_H);
                            active_img_ch <= 6'(L1_IMG_CH);
                            active_kernel <= 3'(L1_KERNEL);
                            active_pad <= 3'(L1_PAD);
                            active_sa_rows <= SA_AW'(((L1_IMG_ROWS + TILE_ROWS - 1) / TILE_ROWS) * L1_K_LEN);
                        end
                        state <= S_RUN;
                    end
                end

                S_RUN: begin
                    if (req_valid && req_ready) begin
                        issue_addr <= issue_addr + SA_AW'(1);
                        if (issue_addr == active_sa_rows - SA_AW'(1)) begin
                            state <= S_DRAIN;
                        end
                    end
                end

                S_DRAIN: begin
                    if (!out_valid && !issue_valid_d) begin
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
