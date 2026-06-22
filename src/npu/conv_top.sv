`timescale 1ns / 1ps

module conv_top #(
    parameter string IMAGE_DATA_FILE = "image_data.dat",
    parameter string CONV1_FILE      = "conv1.dat",
    parameter string CONV2_FILE      = "conv2.dat",
    parameter string BIAS1_FILE      = "bias1.dat",
    parameter string BIAS2_FILE      = "bias2.dat",
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

    output logic final_pool_wr_en,
    output logic [POOL_AW-1:0] final_pool_wr_addr,
    output logic [OUT_DW-1:0] final_pool_wr_data,

    input  logic result_valid,
    input  logic [3:0] result_class_id,
    input  logic [7:0] result_logit,

    output logic mac_dbg_tile_valid,
    output logic [(10*8*4*4*8)-1:0] mac_dbg_tile_data,

    // npu_ram read port (for loading image_buf from DMA-written data)
    output logic [31:0] pixel_rd_addr,
    input  logic [31:0] pixel_rd_data,

    // Load control: pulse img_load_start to trigger npu_ram → image_buf copy
    input  logic img_load_start,
    output logic img_load_done
);

    logic csr_start_pulse;
    logic csr_layer_sel;
    logic [5:0] cfg_in_w;
    logic [5:0] cfg_in_h;
    logic [5:0] cfg_in_ch;
    logic [2:0] cfg_kernel;
    logic [2:0] cfg_pad;
    logic [9:0] cfg_row_base;
    logic [9:0] cfg_k_len;

    logic dmac_busy;
    logic dmac_done;
    logic dmac_start;
    logic dmac_layer_sel;
    logic dmac_ram_wr;
    logic [SA_AW-1:0] dmac_ram_waddr;
    logic [SA_DW-1:0] dmac_ram_wdata;

    logic [23:0] image_rom_data;
    logic [255:0] conv1_rom_data;
    logic [511:0] conv2_rom_data;
    logic [9:0] image_rom_addr;
    logic [6:0] conv1_rom_addr;
    logic [9:0] conv2_rom_addr;

    logic mac_start;
    logic mac_layer_sel;
    logic mac_out_pass;
    logic [15:0] mac_active_k;
    logic [15:0] mac_active_out_rows;
    logic [1:0] mac_result_stride;
    logic [1:0] mac_result_offset;
    logic [4:0] mac_out_shift;
    logic mac_a_valid;
    logic [SA_DW-1:0] mac_a_data;
    logic mac_a_ready;
    logic mac_tile_valid;
    logic [(10*8*4*4*8)-1:0] mac_tile_data;
    logic mac_result_done;
    logic mac_running;
    logic mac_done_pulse;
    logic top_done_pulse;

    localparam int L1_K_DIM = 75;
    localparam int L2_K_DIM = 800;
    localparam int L1_TILE_COUNT = (OUT_ROWS + TILE_ROWS - 1) / TILE_ROWS;
    localparam int L2_OUT_ROWS = 256;
    localparam int L2_TILE_COUNT = (L2_OUT_ROWS + TILE_ROWS - 1) / TILE_ROWS;

    typedef enum logic [2:0] {
        P_IDLE,
        P_LAYER1,
        P_LAYER2_DMAC,
        P_LAYER2_MAC_PASS0,
        P_LAYER2_MAC_PASS1
    } run_phase_t;

    typedef enum logic [2:0] {
        M_IDLE,
        M_WAIT_DMAC,
        M_FEED,
        M_WAIT_TILE
    } mac_ctrl_state_t;

    run_phase_t run_phase;
    mac_ctrl_state_t mac_ctrl_state;
    logic image_sa_rd_en;
    logic [SA_AW-1:0] image_sa_rd_addr;
    logic [SA_DW-1:0] image_sa_rd_data;
    logic mac_sa_rd_en;
    logic [SA_AW-1:0] mac_sa_rd_addr;
    logic mac_rd_valid_q;
    logic [9:0] mac_reads_issued;
    logic [9:0] mac_feeds_sent;
    logic [4:0] mac_tile_idx;
    logic mac_last_tile_captured;
    logic result_ram_wr;
    logic [OUT_AW-1:0] result_ram_waddr;
    logic [OUT_DW-1:0] result_ram_wdata;
    logic mac_result_busy;
    logic ppu_pool_wr;
    logic [POOL_AW-1:0] ppu_pool_waddr;
    logic [OUT_DW-1:0] ppu_pool_wdata;
    logic ppu_start;
    logic [5:0] ppu_cfg_in_size;
    logic [5:0] ppu_cfg_out_size;
    logic [1:0] ppu_cfg_addr_stride;
    logic [1:0] ppu_cfg_addr_offset;
    logic ppu_busy;
    logic ppu_frame_done;
    logic ppu_done_seen;

    assign busy = dmac_busy || mac_running || ppu_busy || (run_phase != P_IDLE);
    assign done = top_done_pulse;
    assign final_pool_wr_en = ppu_pool_wr &&
                              ((run_phase == P_LAYER2_MAC_PASS0) ||
                               (run_phase == P_LAYER2_MAC_PASS1));
    assign final_pool_wr_addr = ppu_pool_waddr;
    assign final_pool_wr_data = ppu_pool_wdata;

    npu_csr_regs u_csr (
        .clk(clk),
        .rst_n(rst_n),
        .csr_wr_en(csr_wr_en),
        .csr_rd_en(csr_rd_en),
        .csr_addr(csr_addr),
        .csr_wdata(csr_wdata),
        .csr_rdata(csr_rdata),
        .dmac_busy(dmac_busy),
        .dmac_done(dmac_done),
        .result_valid(result_valid),
        .result_class_id(result_class_id),
        .result_logit(result_logit),
        .start_pulse(csr_start_pulse),
        .layer_sel(csr_layer_sel),
        .cfg_in_w(cfg_in_w),
        .cfg_in_h(cfg_in_h),
        .cfg_in_ch(cfg_in_ch),
        .cfg_kernel(cfg_kernel),
        .cfg_pad(cfg_pad),
        .cfg_row_base(cfg_row_base),
        .cfg_k_len(cfg_k_len)
    );

    rom #(
        .FILE(IMAGE_DATA_FILE),
        .AW(10),
        .DW(24),
        .ROM_DEPTH(IMG_PIXELS)
    ) u_image_rom (
        .clk(clk),
        .rst_n(rst_n),
        .instr_addr(image_rom_addr),
        .instr_out(image_rom_data)
    );

    rom #(
        .FILE(CONV1_FILE),
        .AW(7),
        .DW(256),
        .ROM_DEPTH(75)
    ) u_conv1_rom (
        .clk(clk),
        .rst_n(rst_n),
        .instr_addr(conv1_rom_addr),
        .instr_out(conv1_rom_data)
    );

    rom #(
        .FILE(CONV2_FILE),
        .AW(10),
        .DW(512),
        .ROM_DEPTH(800)
    ) u_conv2_rom (
        .clk(clk),
        .rst_n(rst_n),
        .instr_addr(conv2_rom_addr),
        .instr_out(conv2_rom_data)
    );

    assign image_rom_addr = 10'd0;
    assign conv1_rom_addr = 7'd0;
    assign conv2_rom_addr = 10'd0;

    dmac_image_sa_writer #(
        .IMAGE_DATA_FILE(IMAGE_DATA_FILE)
    ) u_dmac (
        .clk(clk),
        .rst_n(rst_n),
        .start(dmac_start),
        .layer_sel(dmac_layer_sel),
        .pool_wr_en(ppu_pool_wr),
        .pool_wr_pixel(ppu_pool_waddr),
        .pool_wr_data(ppu_pool_wdata),
        .ram_wr(dmac_ram_wr),
        .ram_waddr(dmac_ram_waddr),
        .ram_wdata(dmac_ram_wdata),
        .busy(dmac_busy),
        .done(dmac_done),
        // npu_ram read port
        .pixel_rd_addr(pixel_rd_addr),
        .pixel_rd_data(pixel_rd_data),
        // Load control
        .load_start(img_load_start),
        .load_done(img_load_done)
    );

    ram #(
        .DEPTH(SA_ROWS),
        .AW(SA_AW),
        .DW(SA_DW)
    ) u_image_sa_ram (
        .clk(clk),
        .wr_en(dmac_ram_wr),
        .wr_addr(dmac_ram_waddr),
        .wr_data(dmac_ram_wdata),
        .rd_en(image_sa_rd_en),
        .rd_addr(image_sa_rd_addr),
        .rd_data(image_sa_rd_data)
    );

    ram #(
        .DEPTH(OUT_ROWS),
        .AW(OUT_AW),
        .DW(OUT_DW)
    ) u_result_ram (
        .clk(clk),
        .wr_en(result_ram_wr),
        .wr_addr(result_ram_waddr),
        .wr_data(result_ram_wdata),
        .rd_en(dbg_result_rd_en),
        .rd_addr(dbg_result_rd_addr),
        .rd_data(dbg_result_rd_data)
    );

    ram #(
        .DEPTH(POOL_ROWS),
        .AW(POOL_AW),
        .DW(OUT_DW)
    ) u_pool_ram (
        .clk(clk),
        .wr_en(ppu_pool_wr),
        .wr_addr(ppu_pool_waddr),
        .wr_data(ppu_pool_wdata),
        .rd_en(dbg_pool_rd_en),
        .rd_addr(dbg_pool_rd_addr),
        .rd_data(dbg_pool_rd_data)
    );

    assign image_sa_rd_en = (mac_ctrl_state == M_FEED) ? mac_sa_rd_en : dbg_sa_rd_en;
    assign image_sa_rd_addr = (mac_ctrl_state == M_FEED) ? mac_sa_rd_addr : dbg_sa_rd_addr;
    assign dbg_sa_rd_data = image_sa_rd_data;
    assign mac_a_valid = (mac_ctrl_state == M_FEED) && mac_rd_valid_q && mac_a_ready;
    assign mac_a_data = image_sa_rd_data;

    mac_array_40x32_stream #(
        .W_FILE(CONV1_FILE),
        .W2_FILE(CONV2_FILE),
        .BIAS_FILE(BIAS1_FILE),
        .BIAS2_FILE(BIAS2_FILE),
        .MAX_DOT_K(800),
        .L1_DOT_K(75),
        .L2_DOT_K(800)
    ) u_mac (
        .clk(clk),
        .rst_n(rst_n),
        .start(mac_start),
        .tile_base_row(OUT_AW'(mac_tile_idx * TILE_ROWS)),
        .layer_sel(mac_layer_sel),
        .out_pass(mac_out_pass),
        .active_dot_k(mac_active_k),
        .active_out_rows(mac_active_out_rows),
        .result_addr_stride(mac_result_stride),
        .result_addr_offset(mac_result_offset),
        .signed_mode(1'b1),
        .out_shift(mac_out_shift),
        .relu_en(1'b1),
        .a_col_valid(mac_a_valid),
        .a_col_320b(mac_a_data),
        .a_col_ready(mac_a_ready),
        .tile_valid(mac_tile_valid),
        .tile_data(mac_tile_data),
        .result_wr_en(result_ram_wr),
        .result_wr_addr(result_ram_waddr),
        .result_wr_data(result_ram_wdata),
        .result_busy(mac_result_busy),
        .result_done(mac_result_done)
    );

    ppu_maxpool #(
        .IN_SIZE(32),
        .CHANNELS(32),
        .IN_ROWS(OUT_ROWS),
        .OUT_SIZE(16),
        .DATA_DW(OUT_DW),
        .IN_AW(OUT_AW),
        .OUT_AW(POOL_AW)
    ) u_ppu (
        .clk(clk),
        .rst_n(rst_n),
        .start(ppu_start),
        .cfg_in_size(ppu_cfg_in_size),
        .cfg_out_size(ppu_cfg_out_size),
        .cfg_addr_stride(ppu_cfg_addr_stride),
        .cfg_addr_offset(ppu_cfg_addr_offset),
        .in_valid(result_ram_wr &&
                  ((run_phase == P_LAYER1) ||
                   (run_phase == P_LAYER2_MAC_PASS0) ||
                   (run_phase == P_LAYER2_MAC_PASS1))),
        .in_row_idx((run_phase == P_LAYER1) ? result_ram_waddr : OUT_AW'(result_ram_waddr >> 1)),
        .in_data(result_ram_wdata),
        .pool_wr_en(ppu_pool_wr),
        .pool_wr_addr(ppu_pool_waddr),
        .pool_wr_data(ppu_pool_wdata),
        .busy(ppu_busy),
        .frame_done(ppu_frame_done)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_ctrl_state <= M_IDLE;
            mac_start <= 1'b0;
            mac_layer_sel <= 1'b0;
            mac_out_pass <= 1'b0;
            mac_active_k <= 16'(L1_K_DIM);
            mac_active_out_rows <= 16'(OUT_ROWS);
            mac_result_stride <= 2'd1;
            mac_result_offset <= 2'd0;
            mac_out_shift <= 5'd7;
            mac_running <= 1'b0;
            mac_done_pulse <= 1'b0;
            top_done_pulse <= 1'b0;
            dmac_start <= 1'b0;
            dmac_layer_sel <= 1'b0;
            ppu_start <= 1'b0;
            ppu_cfg_in_size <= 6'd32;
            ppu_cfg_out_size <= 6'd16;
            ppu_cfg_addr_stride <= 2'd1;
            ppu_cfg_addr_offset <= 2'd0;
            run_phase <= P_IDLE;
            mac_sa_rd_en <= 1'b0;
            mac_sa_rd_addr <= '0;
            mac_rd_valid_q <= 1'b0;
            mac_reads_issued <= '0;
            mac_feeds_sent <= '0;
            mac_tile_idx <= '0;
            mac_last_tile_captured <= 1'b0;
            ppu_done_seen <= 1'b0;
            mac_dbg_tile_valid <= 1'b0;
            mac_dbg_tile_data <= '0;
        end else begin
            mac_start <= 1'b0;
            mac_done_pulse <= 1'b0;
            top_done_pulse <= 1'b0;
            dmac_start <= 1'b0;
            ppu_start <= 1'b0;
            mac_sa_rd_en <= 1'b0;
            mac_rd_valid_q <= mac_sa_rd_en;
            if (ppu_frame_done) begin
                ppu_done_seen <= 1'b1;
            end

            unique case (mac_ctrl_state)
                M_IDLE: begin
                    mac_running <= 1'b0;
                    if (csr_start_pulse) begin
                        dmac_start <= 1'b1;
                        dmac_layer_sel <= 1'b0;
                        ppu_start <= 1'b1;
                        ppu_cfg_in_size <= 6'd32;
                        ppu_cfg_out_size <= 6'd16;
                        ppu_cfg_addr_stride <= 2'd1;
                        ppu_cfg_addr_offset <= 2'd0;
                        run_phase <= P_LAYER1;
                        mac_running <= 1'b1;
                        mac_layer_sel <= 1'b0;
                        mac_out_pass <= 1'b0;
                        mac_active_k <= 16'(L1_K_DIM);
                        mac_active_out_rows <= 16'(OUT_ROWS);
                        mac_result_stride <= 2'd1;
                        mac_result_offset <= 2'd0;
                        mac_out_shift <= 5'd7;
                        mac_dbg_tile_valid <= 1'b0;
                        mac_tile_idx <= 5'd0;
                        mac_last_tile_captured <= 1'b0;
                        ppu_done_seen <= 1'b0;
                        mac_ctrl_state <= M_WAIT_DMAC;
                    end
                end

                M_WAIT_DMAC: begin
                    if (dmac_done && (run_phase == P_LAYER1)) begin
                        mac_start <= 1'b1;
                        mac_reads_issued <= 10'd0;
                        mac_feeds_sent <= 10'd0;
                        mac_ctrl_state <= M_FEED;
                    end else if (dmac_done && (run_phase == P_LAYER2_DMAC)) begin
                        run_phase <= P_LAYER2_MAC_PASS0;
                        ppu_start <= 1'b1;
                        ppu_cfg_in_size <= 6'd16;
                        ppu_cfg_out_size <= 6'd8;
                        ppu_cfg_addr_stride <= 2'd2;
                        ppu_cfg_addr_offset <= 2'd0;
                        mac_running <= 1'b1;
                        mac_layer_sel <= 1'b1;
                        mac_out_pass <= 1'b0;
                        mac_active_k <= 16'(L2_K_DIM);
                        mac_active_out_rows <= 16'(L2_OUT_ROWS);
                        mac_result_stride <= 2'd2;
                        mac_result_offset <= 2'd0;
                        mac_out_shift <= 5'd8;
                        mac_tile_idx <= 5'd0;
                        mac_last_tile_captured <= 1'b0;
                        mac_start <= 1'b1;
                        mac_reads_issued <= 10'd0;
                        mac_feeds_sent <= 10'd0;
                        mac_ctrl_state <= M_FEED;
                    end
                end

                M_FEED: begin
                    if (mac_reads_issued < mac_active_k[9:0]) begin
                        mac_sa_rd_en <= 1'b1;
                        mac_sa_rd_addr <= SA_AW'(mac_tile_idx * mac_active_k + mac_reads_issued);
                        mac_reads_issued <= mac_reads_issued + 10'd1;
                    end

                    if (mac_a_valid && mac_a_ready) begin
                        mac_feeds_sent <= mac_feeds_sent + 10'd1;
                        if (mac_feeds_sent == mac_active_k[9:0] - 10'd1) begin
                            mac_ctrl_state <= M_WAIT_TILE;
                        end
                    end
                end

                M_WAIT_TILE: begin
                    if (mac_tile_valid) begin
                        if (!mac_layer_sel && (mac_tile_idx == 5'd0)) begin
                            mac_dbg_tile_valid <= 1'b1;
                            mac_dbg_tile_data <= mac_tile_data;
                        end
                        if (!mac_layer_sel) begin
                            if (mac_tile_idx == L1_TILE_COUNT[4:0] - 5'd1) begin
                                mac_last_tile_captured <= 1'b1;
                                mac_ctrl_state <= M_WAIT_TILE;
                            end else begin
                                mac_tile_idx <= mac_tile_idx + 5'd1;
                                mac_start <= 1'b1;
                                mac_reads_issued <= 10'd0;
                                mac_feeds_sent <= 10'd0;
                                mac_ctrl_state <= M_FEED;
                            end
                        end else if (mac_tile_idx == L2_TILE_COUNT[4:0] - 5'd1) begin
                            mac_last_tile_captured <= 1'b1;
                            mac_ctrl_state <= M_WAIT_TILE;
                        end else begin
                            mac_tile_idx <= mac_tile_idx + 5'd1;
                            mac_start <= 1'b1;
                            mac_reads_issued <= 10'd0;
                            mac_feeds_sent <= 10'd0;
                            mac_ctrl_state <= M_FEED;
                        end
                    end else if (mac_last_tile_captured && mac_result_done && ppu_done_seen) begin
                        if (!mac_layer_sel) begin
                            mac_last_tile_captured <= 1'b0;
                            ppu_done_seen <= 1'b0;
                            mac_running <= 1'b0;
                            mac_done_pulse <= 1'b1;
                            dmac_start <= 1'b1;
                            dmac_layer_sel <= 1'b1;
                            run_phase <= P_LAYER2_DMAC;
                            mac_ctrl_state <= M_WAIT_DMAC;
                        end else if (run_phase == P_LAYER2_MAC_PASS0) begin
                            mac_last_tile_captured <= 1'b0;
                            ppu_done_seen <= 1'b0;
                            run_phase <= P_LAYER2_MAC_PASS1;
                            mac_out_pass <= 1'b1;
                            mac_result_offset <= 2'd1;
                            mac_tile_idx <= 5'd0;
                            ppu_start <= 1'b1;
                            ppu_cfg_in_size <= 6'd16;
                            ppu_cfg_out_size <= 6'd8;
                            ppu_cfg_addr_stride <= 2'd2;
                            ppu_cfg_addr_offset <= 2'd1;
                            mac_start <= 1'b1;
                            mac_reads_issued <= 10'd0;
                            mac_feeds_sent <= 10'd0;
                            mac_ctrl_state <= M_FEED;
                        end else begin
                            mac_last_tile_captured <= 1'b0;
                            ppu_done_seen <= 1'b0;
                            mac_running <= 1'b0;
                            run_phase <= P_IDLE;
                            top_done_pulse <= 1'b1;
                            mac_ctrl_state <= M_IDLE;
                        end
                    end
                end

                default: mac_ctrl_state <= M_IDLE;
            endcase
        end
    end

endmodule
