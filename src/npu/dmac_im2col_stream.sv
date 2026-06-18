`timescale 1ns / 1ps

// Streaming im2col DMAC.
// One request produces one im2col matrix column for 40 output rows:
//   a_col_320b = {A[row_base+39][k_idx], ..., A[row_base+0][k_idx]}
// The feature maps are kept in on-chip buffers so the 40 lanes can be read in
// parallel. This module is intended to feed the 40 rows of the 40x32 SA.
module dmac_im2col_stream #(
    parameter string IMAGE_DATA_FILE = "image_data.dat",
    parameter int LANE_NUM = 40,
    parameter int MAX_IMG_W = 32,
    parameter int MAX_IMG_H = 32,
    parameter int MAX_POOL_W = 16,
    parameter int MAX_POOL_H = 16,
    parameter int MAX_POOL_CH = 32,
    parameter int PIXEL_AW = 10,
    parameter int POOL_PIXEL_AW = 8
)(
    input  logic clk,
    input  logic rst_n,

    // Pulse for one output column.
    input  logic req_valid,
    output logic req_ready,

    // Layer/config registers.
    // layer_sel=0: image_buf 32x32x3, packed as 24-bit pixels.
    // layer_sel=1: pool_buf  16x16x32, packed as 8 words per pixel.
    input  logic layer_sel,
    input  logic [5:0] cfg_in_w,
    input  logic [5:0] cfg_in_h,
    input  logic [5:0] cfg_in_ch,
    input  logic [2:0] cfg_kernel,
    input  logic [2:0] cfg_pad,

    input  logic [9:0] row_base,
    input  logic [9:0] k_idx,

    // Optional pool feature buffer write port. PPU can fill this buffer before
    // layer2 im2col begins. One word is waveform ordered:
    // [255:248]=ch0, [7:0]=ch31.
    input  logic pool_wr_en,
    input  logic [POOL_PIXEL_AW-1:0] pool_wr_pixel,
    input  logic [MAX_POOL_CH*8-1:0] pool_wr_data,

    output logic out_valid,
    output logic [LANE_NUM*8-1:0] a_col_320b
);

    logic [23:0] image_buf [0:(MAX_IMG_W*MAX_IMG_H)-1];
    logic [MAX_POOL_CH*8-1:0] pool_buf [0:(MAX_POOL_W*MAX_POOL_H)-1];

    assign req_ready = 1'b1;

    initial begin
        integer fd;
        integer row;
        integer code;
        string tok;
        logic [23:0] pix;

        for (row = 0; row < MAX_IMG_W*MAX_IMG_H; row = row + 1) begin
            image_buf[row] = 24'd0;
        end
        for (int p = 0; p < MAX_POOL_W*MAX_POOL_H; p = p + 1) begin
            pool_buf[p] = '0;
        end

        fd = $fopen(IMAGE_DATA_FILE, "r");
        if (fd == 0) begin
            $error("image_data open failed: %s", IMAGE_DATA_FILE);
        end else begin
            row = 0;
            while (($fscanf(fd, "%s", tok) == 1) && (row < MAX_IMG_W*MAX_IMG_H)) begin
                if ((tok.len() >= 2) &&
                    ((tok.substr(0,1) == "0x") || (tok.substr(0,1) == "0X"))) begin
                    tok = tok.substr(2, tok.len()-1);
                end
                code = $sscanf(tok, "%h", pix);
                if (code == 1) begin
                    image_buf[row] = pix;
                end
                row = row + 1;
            end
            $fclose(fd);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            a_col_320b <= '0;
        end else begin
            out_valid <= 1'b0;

            if (pool_wr_en) begin
                pool_buf[pool_wr_pixel] <= pool_wr_data;
            end

            if (req_valid && req_ready) begin
                for (int lane = 0; lane < LANE_NUM; lane = lane + 1) begin
                    a_col_320b[lane*8 +: 8] <= get_lane_data(lane);
                end
                out_valid <= 1'b1;
            end
        end
    end

    function automatic logic [7:0] get_lane_data(input int lane);
        int row;
        int oh;
        int ow;
        int ch;
        int rem;
        int kh;
        int kw;
        int ih;
        int iw;
        int pixel_idx;
        logic [23:0] pixel;
        logic [MAX_POOL_CH*8-1:0] word;
        begin
            row = row_base + lane;
            oh = row / cfg_in_w;
            ow = row % cfg_in_w;
            ch = k_idx / (cfg_kernel * cfg_kernel);
            rem = k_idx % (cfg_kernel * cfg_kernel);
            kh = rem / cfg_kernel;
            kw = rem % cfg_kernel;
            ih = oh + kh - cfg_pad;
            iw = ow + kw - cfg_pad;

            if ((row >= (cfg_in_w * cfg_in_h)) ||
                (ch >= cfg_in_ch) ||
                (ih < 0) || (ih >= cfg_in_h) ||
                (iw < 0) || (iw >= cfg_in_w)) begin
                get_lane_data = 8'd0;
            end else if (!layer_sel) begin
                pixel_idx = ih * cfg_in_w + iw;
                pixel = image_buf[pixel_idx];
                unique case (ch)
                    0: get_lane_data = pixel[23:16];
                    1: get_lane_data = pixel[15:8];
                    default: get_lane_data = pixel[7:0];
                endcase
            end else begin
                pixel_idx = ih * cfg_in_w + iw;
                word = pool_buf[pixel_idx];
                get_lane_data = word[(MAX_POOL_CH-1-ch)*8 +: 8];
            end
        end
    endfunction

endmodule
