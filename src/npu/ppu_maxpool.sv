`timescale 1ns / 1ps

// Streaming 2x2 maxpool for row-major feature maps.
// Input row is one spatial pixel with all channels packed into 256 bits.
module ppu_maxpool #(
    parameter int IN_SIZE  = 32,
    parameter int CHANNELS = 32,
    parameter int IN_ROWS  = IN_SIZE * IN_SIZE,
    parameter int OUT_SIZE = IN_SIZE / 2,
    parameter int DATA_DW  = CHANNELS * 8,
    parameter int IN_AW    = (IN_ROWS <= 1) ? 1 : $clog2(IN_ROWS),
    parameter int OUT_AW   = ((OUT_SIZE*OUT_SIZE) <= 1) ? 1 : $clog2(OUT_SIZE*OUT_SIZE)
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    input  logic [5:0] cfg_in_size,
    input  logic [5:0] cfg_out_size,
    input  logic [1:0] cfg_addr_stride,
    input  logic [1:0] cfg_addr_offset,

    input  logic in_valid,
    input  logic [IN_AW-1:0] in_row_idx,
    input  logic [DATA_DW-1:0] in_data,

    output logic pool_wr_en,
    output logic [OUT_AW-1:0] pool_wr_addr,
    output logic [DATA_DW-1:0] pool_wr_data,
    output logic busy,
    output logic frame_done
);

    logic [DATA_DW-1:0] left_pixel_buf;
    logic [DATA_DW-1:0] row_max_buf [0:OUT_SIZE-1];

    logic [5:0] h_idx;
    logic [5:0] w_idx;
    logic [5:0] pool_h;
    logic [5:0] pool_w;
    logic [DATA_DW-1:0] hmax_data;
    logic [DATA_DW-1:0] vmax_data;

    assign h_idx = in_row_idx / cfg_in_size;
    assign w_idx = in_row_idx % cfg_in_size;
    assign pool_h = h_idx >> 1;
    assign pool_w = w_idx >> 1;
    assign hmax_data = max_vec_i8(left_pixel_buf, in_data);
    assign vmax_data = max_vec_i8(row_max_buf[pool_w], hmax_data);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            left_pixel_buf <= '0;
            pool_wr_en <= 1'b0;
            pool_wr_addr <= '0;
            pool_wr_data <= '0;
            busy <= 1'b0;
            frame_done <= 1'b0;
            for (int i = 0; i < OUT_SIZE; i = i + 1) begin
                row_max_buf[i] <= '0;
            end
        end else begin
            pool_wr_en <= 1'b0;
            frame_done <= 1'b0;

            if (start) begin
                left_pixel_buf <= '0;
                pool_wr_addr <= '0;
                pool_wr_data <= '0;
                busy <= 1'b1;
                for (int i = 0; i < OUT_SIZE; i = i + 1) begin
                    row_max_buf[i] <= '0;
                end
            end else if (in_valid) begin
                busy <= 1'b1;
                if (w_idx[0] == 1'b0) begin
                    left_pixel_buf <= in_data;
                end else if (h_idx[0] == 1'b0) begin
                    row_max_buf[pool_w] <= hmax_data;
                end else begin
                    pool_wr_en <= 1'b1;
                    pool_wr_addr <= OUT_AW'((pool_h * cfg_out_size + pool_w) * cfg_addr_stride + cfg_addr_offset);
                    // Keep the same byte order as the MAC result stream:
                    // ch0 is at [255:248], so a 256-bit hex waveform reads
                    // left-to-right as ch0..ch31.
                    pool_wr_data <= vmax_data;
                    if ((pool_h == cfg_out_size - 6'd1) &&
                        (pool_w == cfg_out_size - 6'd1)) begin
                        frame_done <= 1'b1;
                        busy <= 1'b0;
                    end
                end
            end
        end
    end

    function automatic logic [DATA_DW-1:0] max_vec_i8(
        input logic [DATA_DW-1:0] a,
        input logic [DATA_DW-1:0] b
    );
        logic signed [7:0] av;
        logic signed [7:0] bv;
        begin
            for (int i = 0; i < CHANNELS; i = i + 1) begin
                av = $signed(a[i*8 +: 8]);
                bv = $signed(b[i*8 +: 8]);
                max_vec_i8[i*8 +: 8] = (av >= bv) ? av : bv;
            end
        end
    endfunction

endmodule
