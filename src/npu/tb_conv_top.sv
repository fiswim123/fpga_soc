`timescale 1ns / 1ps

module tb_conv_top;

    localparam int SA_ROWS = 5600;
    localparam int TILE_ROWS = 40;
    localparam int SA_DW = TILE_ROWS * 8;
    localparam int SA_AW = $clog2(SA_ROWS);
    localparam int K_DIM = 75;
    localparam int K2_DIM = 800;
    localparam int OUT_ROWS = 1024;
    localparam int OUT_COLS = 32;
    localparam int OUT_DW = OUT_COLS * 8;
    localparam int OUT_AW = $clog2(OUT_ROWS);
    localparam int POOL_ROWS = 256;
    localparam int POOL_AW = $clog2(POOL_ROWS);
    localparam int SUB_M = 4;
    localparam int ROW_GROUPS = TILE_ROWS / SUB_M;
    localparam int COL_GROUPS = OUT_COLS / SUB_M;
    localparam int SA_RES_DW = SUB_M * SUB_M * 8;
    localparam int MAC_TILE_DW = ROW_GROUPS * COL_GROUPS * SA_RES_DW;

    localparam string IMAGE_DATA_FILE = "../image_data.dat";
    localparam string CONV1_FILE      = "../conv1.dat";
    localparam string CONV2_FILE      = "../conv2.dat";
    localparam string BIAS1_FILE      = "../bias1.dat";
    localparam string BIAS2_FILE      = "../bias2.dat";
    localparam string IMAGE_FILE      = "../image.dat";

    localparam logic [7:0] REG_CTRL   = 8'h00;
    localparam logic [7:0] REG_STATUS = 8'h04;
    localparam logic [7:0] REG_SHAPE0 = 8'h08;
    localparam logic [7:0] REG_SHAPE1 = 8'h0c;
    localparam logic [7:0] REG_TILE   = 8'h10;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n = 1'b0;
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
    end

    logic csr_wr_en;
    logic csr_rd_en;
    logic [7:0] csr_addr;
    logic [31:0] csr_wdata;
    logic [31:0] csr_rdata;
    logic busy;
    logic done;
    logic dbg_sa_rd_en;
    logic [SA_AW-1:0] dbg_sa_rd_addr;
    logic [SA_DW-1:0] dbg_sa_rd_data;
    logic dbg_result_rd_en;
    logic [OUT_AW-1:0] dbg_result_rd_addr;
    logic [OUT_DW-1:0] dbg_result_rd_data;
    logic dbg_pool_rd_en;
    logic [POOL_AW-1:0] dbg_pool_rd_addr;
    logic [OUT_DW-1:0] dbg_pool_rd_data;
    logic final_pool_wr_en;
    logic [POOL_AW-1:0] final_pool_wr_addr;
    logic [OUT_DW-1:0] final_pool_wr_data;
    logic mac_dbg_tile_valid;
    logic [MAC_TILE_DW-1:0] mac_dbg_tile_data;

    logic [(K_DIM*8)-1:0] image_line [0:OUT_ROWS-1];
    logic [(OUT_COLS*8)-1:0] weight_line [0:K_DIM-1];
    logic [(64*8)-1:0] weight2_line [0:K2_DIM-1];
    logic signed [7:0] img [0:OUT_ROWS-1][0:K_DIM-1];
    logic signed [7:0] wt [0:K_DIM-1][0:OUT_COLS-1];
    logic signed [7:0] wt2 [0:K2_DIM-1][0:63];
    logic signed [7:0] bias [0:OUT_COLS-1];
    logic signed [7:0] bias2 [0:63];
    logic signed [7:0] golden [0:OUT_ROWS-1][0:OUT_COLS-1];
    logic signed [7:0] l2_golden [0:255][0:63];

    conv_top #(
        .IMAGE_DATA_FILE(IMAGE_DATA_FILE),
        .CONV1_FILE(CONV1_FILE),
        .CONV2_FILE(CONV2_FILE),
        .BIAS1_FILE(BIAS1_FILE),
        .BIAS2_FILE(BIAS2_FILE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .csr_wr_en(csr_wr_en),
        .csr_rd_en(csr_rd_en),
        .csr_addr(csr_addr),
        .csr_wdata(csr_wdata),
        .csr_rdata(csr_rdata),
        .busy(busy),
        .done(done),
        .dbg_sa_rd_en(dbg_sa_rd_en),
        .dbg_sa_rd_addr(dbg_sa_rd_addr),
        .dbg_sa_rd_data(dbg_sa_rd_data),
        .dbg_result_rd_en(dbg_result_rd_en),
        .dbg_result_rd_addr(dbg_result_rd_addr),
        .dbg_result_rd_data(dbg_result_rd_data),
        .dbg_pool_rd_en(dbg_pool_rd_en),
        .dbg_pool_rd_addr(dbg_pool_rd_addr),
        .dbg_pool_rd_data(dbg_pool_rd_data),
        .final_pool_wr_en(final_pool_wr_en),
        .final_pool_wr_addr(final_pool_wr_addr),
        .final_pool_wr_data(final_pool_wr_data),
        .result_valid(1'b0),
        .result_class_id(4'd0),
        .result_logit(8'd0),
        .result_logits_flat(80'd0),
        .mac_dbg_tile_valid(mac_dbg_tile_valid),
        .mac_dbg_tile_data(mac_dbg_tile_data)
    );

    initial begin
        int mismatches;
        logic [SA_DW-1:0] got;

        build_mac_golden();

        csr_wr_en = 1'b0;
        csr_rd_en = 1'b0;
        csr_addr = '0;
        csr_wdata = '0;
        dbg_sa_rd_en = 1'b0;
        dbg_sa_rd_addr = '0;
        dbg_result_rd_en = 1'b0;
        dbg_result_rd_addr = '0;
        dbg_pool_rd_en = 1'b0;
        dbg_pool_rd_addr = '0;

        wait (rst_n);
        repeat (3) @(posedge clk);

        // Configure conv1 DMAC: 32x32x3, kernel=5, pad=2, k_len=75.
        csr_write(REG_SHAPE0, {10'd0, 6'd3, 2'd0, 6'd32, 2'd0, 6'd32});
        csr_write(REG_SHAPE1, {6'd0, 10'd75, 5'd0, 3'd2, 5'd0, 3'd5});
        csr_write(REG_TILE, 32'd0);
        csr_write(REG_CTRL, 32'h0000_0001);

        fork : watchdog
            begin
                wait (done);
                disable watchdog;
            end
            begin
                repeat (50000) @(posedge clk);
                $display("[FAIL] timeout waiting conv_top done");
                $finish;
                disable watchdog;
            end
        join

        repeat (3) @(posedge clk);

        mismatches = 0;
        for (int i = 0; i < SA_ROWS; i = i + 1) begin
            logic [SA_DW-1:0] exp_sa;
            ram_read(i[SA_AW-1:0], got);
            exp_sa = l2_sa_word(i);
            if (got !== exp_sa) begin
                if (mismatches < 12) begin
                    $display("[L2 IM2COL MISMATCH] image_sa_ram[%0d] exp=%080h got=%080h",
                             i, exp_sa, got);
                end
                mismatches++;
            end
        end

        if (!mac_dbg_tile_valid) begin
            $display("[MISMATCH] MAC debug tile was not valid");
            mismatches++;
        end else begin
            for (int r = 0; r < TILE_ROWS; r = r + 1) begin
                for (int c = 0; c < OUT_COLS; c = c + 1) begin
                    logic [7:0] mac_got;
                    logic [7:0] mac_exp;
                    mac_got = get_mac_tile_byte(r, c);
                    mac_exp = golden[r][c];
                    if (mac_got !== mac_exp) begin
                        if (mismatches < 24) begin
                            $display("[MAC MISMATCH] r=%0d c=%0d exp=%02h got=%02h",
                                     r, c, mac_exp, mac_got);
                        end
                        mismatches++;
                    end
                end
            end
        end

        for (int row = 0; row < 256; row = row + 1) begin
            logic [OUT_DW-1:0] got_row;
            logic [OUT_DW-1:0] exp_row;
            for (int pass = 0; pass < 2; pass = pass + 1) begin
                result_ram_read(OUT_AW'(row*2 + pass), got_row);
                for (int c = 0; c < OUT_COLS; c = c + 1) begin
                    exp_row[(OUT_COLS-1-c)*8 +: 8] = l2_golden[row][pass*32 + c];
                end
                if (got_row !== exp_row) begin
                    if (mismatches < 32) begin
                        $display("[L2 RESULT MISMATCH] row=%0d pass=%0d exp=%064h got=%064h",
                                 row, pass, exp_row, got_row);
                    end
                    mismatches++;
                end
            end
        end

        for (int ph = 0; ph < 8; ph = ph + 1) begin
            for (int pw = 0; pw < 8; pw = pw + 1) begin
                logic [OUT_DW-1:0] got_pool;
                logic [OUT_DW-1:0] exp_pool;
                for (int pass = 0; pass < 2; pass = pass + 1) begin
                    pool_ram_read(POOL_AW'((ph * 8 + pw) * 2 + pass), got_pool);
                    for (int c = 0; c < OUT_COLS; c = c + 1) begin
                        exp_pool[(OUT_COLS-1-c)*8 +: 8] = pool2_golden(ph, pw, pass*32 + c);
                    end
                    if (got_pool !== exp_pool) begin
                        if (mismatches < 40) begin
                            $display("[POOL2 MISMATCH] ph=%0d pw=%0d pass=%0d exp=%064h got=%064h",
                                     ph, pw, pass, exp_pool, got_pool);
                        end
                        mismatches++;
                    end
                end
            end
        end

        if (mismatches == 0) begin
            $display("");
            $display("===== PASS: conv_top second-layer result RAM and final 8x8x64 pool RAM match reference =====");
            $display("");
        end else begin
            $display("");
            $display("===== FAIL: %0d conv_top mismatches =====", mismatches);
            $display("");
        end

        $finish;
    end

    task automatic csr_write(input logic [7:0] addr, input logic [31:0] data);
        begin
            @(posedge clk);
            csr_addr <= addr;
            csr_wdata <= data;
            csr_wr_en <= 1'b1;
            @(posedge clk);
            csr_wr_en <= 1'b0;
            csr_addr <= '0;
            csr_wdata <= '0;
        end
    endtask

    task automatic ram_read(input logic [SA_AW-1:0] addr, output logic [SA_DW-1:0] data);
        begin
            dbg_sa_rd_addr = addr;
            dbg_sa_rd_en = 1'b1;
            @(posedge clk);
            #1;
            data = dbg_sa_rd_data;
            dbg_sa_rd_en = 1'b0;
        end
    endtask

    task automatic result_ram_read(input logic [OUT_AW-1:0] addr, output logic [OUT_DW-1:0] data);
        begin
            dbg_result_rd_addr = addr;
            dbg_result_rd_en = 1'b1;
            @(posedge clk);
            #1;
            data = dbg_result_rd_data;
            dbg_result_rd_en = 1'b0;
        end
    endtask

    task automatic pool_ram_read(input logic [POOL_AW-1:0] addr, output logic [OUT_DW-1:0] data);
        begin
            dbg_pool_rd_addr = addr;
            dbg_pool_rd_en = 1'b1;
            @(posedge clk);
            #1;
            data = dbg_pool_rd_data;
            dbg_pool_rd_en = 1'b0;
        end
    endtask

    function automatic [7:0] get_mac_tile_byte(input int r, input int c);
        int rg;
        int cg;
        int rr;
        int cc;
        int bit_idx;
        begin
            rg = r / SUB_M;
            rr = r % SUB_M;
            cg = c / SUB_M;
            cc = c % SUB_M;
            bit_idx = ((rg*COL_GROUPS+cg)*SA_RES_DW) + ((rr*SUB_M+cc)*8);
            get_mac_tile_byte = mac_dbg_tile_data[bit_idx +: 8];
        end
    endfunction

    task automatic build_mac_golden();
        begin
            $readmemh(IMAGE_FILE, image_line);
            $readmemh(CONV1_FILE, weight_line);
            $readmemh(CONV2_FILE, weight2_line);
            $readmemh(BIAS1_FILE, bias);
            $readmemh(BIAS2_FILE, bias2);
            for (int r = 0; r < OUT_ROWS; r = r + 1) begin
                for (int k = 0; k < K_DIM; k = k + 1) begin
                    img[r][k] = $signed(image_line[r][K_DIM*8-1 - k*8 -: 8]);
                end
            end
            for (int k = 0; k < K_DIM; k = k + 1) begin
                for (int c = 0; c < OUT_COLS; c = c + 1) begin
                    wt[k][c] = $signed(weight_line[k][OUT_COLS*8-1 - c*8 -: 8]);
                end
            end
            for (int k = 0; k < K2_DIM; k = k + 1) begin
                for (int c = 0; c < 64; c = c + 1) begin
                    wt2[k][c] = $signed(weight2_line[k][64*8-1 - c*8 -: 8]);
                end
            end
            for (int r = 0; r < OUT_ROWS; r = r + 1) begin
                for (int c = 0; c < OUT_COLS; c = c + 1) begin
                    logic signed [31:0] acc;
                    acc = 32'sd0;
                    for (int k = 0; k < K_DIM; k = k + 1) begin
                        acc += img[r][k] * wt[k][c];
                    end
                    golden[r][c] = postproc(acc, bias[c]);
                end
            end
            for (int r = 0; r < 256; r = r + 1) begin
                for (int c = 0; c < 64; c = c + 1) begin
                    logic signed [31:0] acc2;
                    acc2 = 32'sd0;
                    for (int k = 0; k < K2_DIM; k = k + 1) begin
                        acc2 += l2_im2col_value(r, k) * wt2[k][c];
                    end
                    l2_golden[r][c] = postproc_shift(acc2, bias2[c], 5'd8);
                end
            end
        end
    endtask

    function automatic signed [7:0] postproc(input logic signed [31:0] acc, input logic signed [7:0] b);
        logic signed [7:0] q;
        logic signed [31:0] biased;
        begin
            q = {acc[31], acc[7 +: 7]};
            postproc = postproc_shift(acc, b, 5'd7);
        end
    endfunction

    function automatic signed [7:0] postproc_shift(input logic signed [31:0] acc, input logic signed [7:0] b, input logic [4:0] shift);
        logic signed [7:0] q;
        logic signed [31:0] biased;
        begin
            q = {acc[31], acc[shift +: 7]};
            biased = {{24{q[7]}}, q} + {{24{b[7]}}, b};
            if (biased <= 32'sd0) postproc_shift = 8'sd0;
            else if (biased > 32'sd127) postproc_shift = 8'sd127;
            else postproc_shift = biased[7:0];
        end
    endfunction

    function automatic signed [7:0] pool_golden(input int ph, input int pw, input int c);
        logic signed [7:0] a;
        logic signed [7:0] b;
        logic signed [7:0] d;
        logic signed [7:0] e;
        begin
            a = golden[(ph*2 + 0)*32 + (pw*2 + 0)][c];
            b = golden[(ph*2 + 0)*32 + (pw*2 + 1)][c];
            d = golden[(ph*2 + 1)*32 + (pw*2 + 0)][c];
            e = golden[(ph*2 + 1)*32 + (pw*2 + 1)][c];
            pool_golden = max2_i8(max2_i8(a, b), max2_i8(d, e));
        end
    endfunction

    function automatic signed [7:0] pool2_golden(input int ph, input int pw, input int c);
        logic signed [7:0] a;
        logic signed [7:0] b;
        logic signed [7:0] d;
        logic signed [7:0] e;
        begin
            a = l2_golden[(ph*2 + 0)*16 + (pw*2 + 0)][c];
            b = l2_golden[(ph*2 + 0)*16 + (pw*2 + 1)][c];
            d = l2_golden[(ph*2 + 1)*16 + (pw*2 + 0)][c];
            e = l2_golden[(ph*2 + 1)*16 + (pw*2 + 1)][c];
            pool2_golden = max2_i8(max2_i8(a, b), max2_i8(d, e));
        end
    endfunction

    function automatic signed [7:0] max2_i8(input logic signed [7:0] a, input logic signed [7:0] b);
        begin
            max2_i8 = (a >= b) ? a : b;
        end
    endfunction

    function automatic [SA_DW-1:0] l2_sa_word(input int addr);
        int tile_idx;
        int k;
        int row_base;
        begin
            tile_idx = addr / K2_DIM;
            k = addr % K2_DIM;
            row_base = tile_idx * TILE_ROWS;
            for (int lane = 0; lane < TILE_ROWS; lane = lane + 1) begin
                l2_sa_word[SA_DW-1 - lane*8 -: 8] = l2_im2col_value(row_base + lane, k);
            end
        end
    endfunction

    function automatic signed [7:0] l2_im2col_value(input int out_row, input int k);
        int oh;
        int ow;
        int ic;
        int rem;
        int kh;
        int kw;
        int ih;
        int iw;
        begin
            oh = out_row / 16;
            ow = out_row % 16;
            ic = k / 25;
            rem = k % 25;
            kh = rem / 5;
            kw = rem % 5;
            ih = oh + kh - 2;
            iw = ow + kw - 2;
            if ((out_row >= 256) || (ic >= 32) ||
                (ih < 0) || (ih >= 16) || (iw < 0) || (iw >= 16)) begin
                l2_im2col_value = 8'sd0;
            end else begin
                l2_im2col_value = pool_golden(ih, iw, ic);
            end
        end
    endfunction

endmodule
