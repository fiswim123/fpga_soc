//===================================================================== 
// Description: 
// mm systolic PE unit
//======================= 

module pe #(
    parameter int DOT_K = 75
)(
    input logic clk,
    input logic rst_n,
    input logic flush,

    input logic signed [7:0] row_i,
    input logic signed [7:0] col_i,
    input logic din_valid,
    input logic signed_mode,
    input logic [15:0] dot_k,

    output logic [7:0] row_o,
    output logic [7:0] col_o,
    output logic dout_valid,

    output logic signed [31:0] res,
    output logic res_valid,
    input logic add_mode,          //1 for add , 0 for mul
    input logic add_compute_valid  //1 for plus,0 for stay 
);

logic signed [31:0] acc;
logic signed [31:0] op_res;
logic               do_compute;
logic [15:0]        mac_cnt;

always @* begin
    do_compute = din_valid;
    op_res = 32'sd0;

    if (add_mode) begin
        if (add_compute_valid) begin
            op_res = $signed(row_i) + $signed(col_i);
        end else begin
            do_compute = 1'b0;
            op_res = 32'sd0;
        end
    end else begin
        if (signed_mode) begin
            op_res = $signed({{24{row_i[7]}}, row_i}) * $signed({{24{col_i[7]}}, col_i});
        end else begin
            op_res = $signed({24'b0, row_i}) * $signed({24'b0, col_i});
        end
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        row_o <= 8'd0;
        col_o <= 8'd0;
        dout_valid <= 1'b0;
    end else begin
        row_o <= row_i;
        col_o <= col_i;
        dout_valid <= din_valid;
    end
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        res <= 32'sd0;
        acc <= 32'sd0;
        mac_cnt <= 16'd0;
        res_valid <= 1'b0;
    end else begin
        res_valid <= 1'b0;
        if (flush) begin
            // If flush and valid data arrive together, treat it as the first
            // MAC beat of a new dot-product instead of dropping this beat.
            if (do_compute) begin
                acc <= op_res;
                mac_cnt <= 16'd1;
            end else begin
                acc <= 32'sd0;
                mac_cnt <= 16'd0;
            end
        end else if (do_compute) begin
            if (mac_cnt == (dot_k - 16'd1)) begin
                res <= acc + op_res;
                res_valid <= 1'b1;
                acc <= 32'sd0;
                mac_cnt <= 16'd0;
            end else begin
                acc <= acc + op_res;
                mac_cnt <= mac_cnt + 1'b1;
            end
        end
    end
end

endmodule
