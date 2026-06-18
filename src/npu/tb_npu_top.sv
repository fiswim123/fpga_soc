`timescale 1ns / 1ps

module tb_npu_top;

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
    localparam int FC_IN = 64;
    localparam int FC_OUT = 10;

    localparam string IMAGE_DATA_FILE = "../image_data.dat";
    localparam string CONV1_FILE      = "../conv1.dat";
    localparam string CONV2_FILE      = "../conv2.dat";
    localparam string BIAS1_FILE      = "../bias1.dat";
    localparam string BIAS2_FILE      = "../bias2.dat";
    localparam string IMAGE_FILE      = "../image.dat";
    localparam string FC_WEIGHT_FILE  = "../export_cifar/cifar10_int8_pow2_fused/fc_weight_i8.memh";
    localparam string FC_BIAS_FILE    = "../export_cifar/cifar10_int8_pow2_fused_bias_i8/fc_bias_i8.memh";

    localparam logic [7:0] REG_CTRL   = 8'h00;
    localparam logic [7:0] REG_STATUS = 8'h04;
    localparam logic [7:0] REG_SHAPE0 = 8'h08;
    localparam logic [7:0] REG_SHAPE1 = 8'h0c;
    localparam logic [7:0] REG_TILE   = 8'h10;
    localparam logic [7:0] REG_PRED   = 8'h20;
    localparam logic [7:0] REG_LOGIT0 = 8'h24;
    localparam logic [7:0] REG_LOGIT1 = 8'h28;
    localparam logic [7:0] REG_LOGIT2 = 8'h2c;

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
    logic dbg_logit_rd_en;
    logic [3:0] dbg_logit_rd_addr;
    logic [7:0] dbg_logit_rd_data;
    logic pred_valid;
    logic [3:0] pred_class_id;
    logic [7:0] pred_logit;
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
    logic signed [7:0] fc_weight_flat [0:(FC_OUT*FC_IN)-1];
    logic signed [7:0] fc_bias [0:FC_OUT-1];
    logic signed [7:0] golden [0:OUT_ROWS-1][0:OUT_COLS-1];
    logic signed [7:0] l2_golden [0:255][0:63];
    logic signed [7:0] gap_golden [0:FC_IN-1];
    logic signed [7:0] logit_golden [0:FC_OUT-1];
    logic signed [7:0] got_logits [0:FC_OUT-1];

    npu_top #(
        .IMAGE_DATA_FILE(IMAGE_DATA_FILE),
        .CONV1_FILE(CONV1_FILE),
        .CONV2_FILE(CONV2_FILE),
        .BIAS1_FILE(BIAS1_FILE),
        .BIAS2_FILE(BIAS2_FILE),
        .FC_WEIGHT_FILE(FC_WEIGHT_FILE),
        .FC_BIAS_FILE(FC_BIAS_FILE)
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
        .dbg_logit_rd_en(dbg_logit_rd_en),
        .dbg_logit_rd_addr(dbg_logit_rd_addr),
        .dbg_logit_rd_data(dbg_logit_rd_data),
        .pred_valid(pred_valid),
        .pred_class_id(pred_class_id),
        .pred_logit(pred_logit),
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
        dbg_logit_rd_en = 1'b0;
        dbg_logit_rd_addr = '0;

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

        for (int cls = 0; cls < FC_OUT; cls = cls + 1) begin
            logic [7:0] got_logit;
            logic [7:0] exp_logit;
            logit_read(4'(cls), got_logit);
            got_logits[cls] = $signed(got_logit);
            exp_logit = fc_logit_expected(cls);
            if (got_logit !== exp_logit) begin
                if (mismatches < 48) begin
                    $display("[LOGIT MISMATCH] cls=%0d exp=%02h got=%02h",
                             cls, exp_logit, got_logit);
                end
                mismatches++;
            end
        end

        $display("[LOGITS] %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                 got_logits[0], got_logits[1], got_logits[2], got_logits[3], got_logits[4],
                 got_logits[5], got_logits[6], got_logits[7], got_logits[8], got_logits[9]);
        if (!pred_valid) begin
            $display("[PRED MISMATCH] pred_valid was not asserted");
            mismatches++;
        end else if ((pred_class_id !== 4'(argmax_logits())) ||
                     ($signed(pred_logit) !== got_logits[argmax_logits()])) begin
            $display("[PRED MISMATCH] exp_class=%0d exp_logit=%0d got_class=%0d got_logit=%0d",
                     argmax_logits(), got_logits[argmax_logits()], pred_class_id, $signed(pred_logit));
            mismatches++;
        end
        $display("[PRED] class_id=%0d logit=%0d", pred_class_id, $signed(pred_logit));

        check_result_csrs(mismatches);

        if (mismatches == 0) begin
            $display("");
            $display("===== PASS: npu_top final pool RAM and 10 logits match reference =====");
            $display("");
        end else begin
            $display("");
            $display("===== FAIL: %0d npu_top mismatches =====", mismatches);
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

    task automatic csr_read(input logic [7:0] addr, output logic [31:0] data);
        begin
            @(posedge clk);
            csr_addr <= addr;
            csr_rd_en <= 1'b1;
            @(posedge clk);
            #1;
            data = csr_rdata;
            csr_rd_en <= 1'b0;
            csr_addr <= '0;
        end
    endtask

    task automatic check_result_csrs(ref int mismatches);
        logic [31:0] pred_csr;
        logic [31:0] logit0_csr;
        logic [31:0] logit1_csr;
        logic [31:0] logit2_csr;
        begin
            csr_read(REG_PRED, pred_csr);
            csr_read(REG_LOGIT0, logit0_csr);
            csr_read(REG_LOGIT1, logit1_csr);
            csr_read(REG_LOGIT2, logit2_csr);

            if ((pred_csr[0] !== 1'b1) ||
                (pred_csr[11:8] !== pred_class_id) ||
                (pred_csr[23:16] !== pred_logit) ||
                (pred_csr[31:24] !== {8{pred_logit[7]}})) begin
                $display("[CSR PRED MISMATCH] exp_valid=1 exp_class=%0d exp_logit=%02h got=%08h",
                         pred_class_id, pred_logit, pred_csr);
                mismatches++;
            end

            for (int cls = 0; cls < 4; cls = cls + 1) begin
                if (logit0_csr[cls*8 +: 8] !== got_logits[cls]) begin
                    $display("[CSR LOGIT MISMATCH] cls=%0d exp=%02h got=%02h",
                             cls, got_logits[cls], logit0_csr[cls*8 +: 8]);
                    mismatches++;
                end
            end
            for (int cls = 4; cls < 8; cls = cls + 1) begin
                if (logit1_csr[(cls-4)*8 +: 8] !== got_logits[cls]) begin
                    $display("[CSR LOGIT MISMATCH] cls=%0d exp=%02h got=%02h",
                             cls, got_logits[cls], logit1_csr[(cls-4)*8 +: 8]);
                    mismatches++;
                end
            end
            for (int cls = 8; cls < 10; cls = cls + 1) begin
                if (logit2_csr[(cls-8)*8 +: 8] !== got_logits[cls]) begin
                    $display("[CSR LOGIT MISMATCH] cls=%0d exp=%02h got=%02h",
                             cls, got_logits[cls], logit2_csr[(cls-8)*8 +: 8]);
                    mismatches++;
                end
            end
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

    task automatic logit_read(input logic [3:0] addr, output logic [7:0] data);
        begin
            dbg_logit_rd_addr = addr;
            dbg_logit_rd_en = 1'b1;
            @(posedge clk);
            #1;
            data = dbg_logit_rd_data;
            dbg_logit_rd_en = 1'b0;
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
            $readmemh(FC_WEIGHT_FILE, fc_weight_flat);
            $readmemh(FC_BIAS_FILE, fc_bias);
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
            for (int c = 0; c < FC_IN; c = c + 1) begin
                logic signed [31:0] gap_acc;
                gap_acc = 32'sd0;
                for (int ph = 0; ph < 8; ph = ph + 1) begin
                    for (int pw = 0; pw < 8; pw = pw + 1) begin
                        gap_acc += pool2_golden(ph, pw, c);
                    end
                end
                gap_golden[c] = sat_i8(gap_acc >>> 6);
            end
            for (int cls = 0; cls < FC_OUT; cls = cls + 1) begin
                logit_golden[cls] = fc_logit_expected(cls);
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

    function automatic signed [7:0] sat_i8(input logic signed [31:0] vin);
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

    function automatic signed [31:0] sext_i8(input logic signed [7:0] value);
        begin
            sext_i8 = {{24{value[7]}}, value};
        end
    endfunction

    function automatic signed [7:0] fc_logit_expected(input int cls);
        logic signed [31:0] sum;
        logic signed [31:0] biased;
        begin
            sum = 32'sd0;
            for (int c = 0; c < FC_IN; c = c + 1) begin
                sum += sext_i8(gap_golden[c]) * sext_i8(fc_weight_flat[cls * FC_IN + c]);
            end
            biased = (sum >>> 7) + sext_i8(fc_bias[cls]);
            fc_logit_expected = sat_i8(biased);
        end
    endfunction

    function automatic int argmax_logits();
        int best;
        begin
            best = 0;
            for (int cls = 1; cls < FC_OUT; cls = cls + 1) begin
                if (got_logits[cls] > got_logits[best]) begin
                    best = cls;
                end
            end
            argmax_logits = best;
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
