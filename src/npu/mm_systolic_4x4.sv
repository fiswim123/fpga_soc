//===================================================================== 
// Description: 
// 4x4 Systolic Array Matrix Multiplication Module 
// ==================================================================== 

module mm_systolic_4x4 #(
    parameter int DOT_K = 5
)(
    input  logic clk,
    input  logic rst_n,

    input  logic signed_mode,          
    input  logic [31:0] row_bar,     // 4 elements * 8bit = 32bit
    input  logic [31:0] col_bar,     // 4 elements * 8bit = 32bit
    input  logic bar_valid,
    input  logic [15:0] dot_k,
    input  logic [4:0] out_shift,
    input  logic [4*8-1:0] bias_vec,
    input  logic relu_en,

    output logic [(4*4*8)-1:0]  res,
    output logic [15:0]         res_valid,
        
    input  logic flush,
    input  logic add_mode,
    input  logic add_compute_valid              
);

wire signed [31:0] pe_res [0:3][0:3];
wire               pe_res_valid [0:3][0:3];
wire signed [7:0]  pe_res_i8 [0:3][0:3];
wire signed [7:0]  pe_post_i8 [0:3][0:3];
wire signed [31:0] biased_val [0:3][0:3];

// [ ---------------------- divide bar into 4x4 inputs ---------------------- ]
wire [7:0] row_in [0:3];
wire [7:0] col_in [0:3];

// 按照原代码逻辑进行切分
assign {row_in[0], row_in[1], row_in[2], row_in[3]} = row_bar;
assign {col_in[0], col_in[1], col_in[2], col_in[3]} = col_bar;


// [ ---------------------- input delay pattern ---------------------- ]
// 4x4 阵列需要最多 3 拍延迟
reg [7:0] row_d1 [1:3], col_d1 [1:3]; // 第一级延迟
reg [7:0] row_d2 [2:3], col_d2 [2:3]; // 第二级延迟
reg [7:0] row_d3 [3:3], col_d3 [3:3]; // 第三级延迟

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 初始化延迟寄存器
        integer k;
        for(k=1; k<=3; k=k+1) begin row_d1[k] <= 8'h0; col_d1[k] <= 8'h0; end
        for(k=2; k<=3; k=k+1) begin row_d2[k] <= 8'h0; col_d2[k] <= 8'h0; end
        for(k=3; k<=3; k=k+1) begin row_d3[k] <= 8'h0; col_d3[k] <= 8'h0; end
    end else begin
        // 第一级
        row_d1[1] <= row_in[1]; col_d1[1] <= col_in[1];
        row_d1[2] <= row_in[2]; col_d1[2] <= col_in[2];
        row_d1[3] <= row_in[3]; col_d1[3] <= col_in[3];
        // 第二级
        row_d2[2] <= row_d1[2]; col_d2[2] <= col_d1[2];
        row_d2[3] <= row_d1[3]; col_d2[3] <= col_d1[3];
        // 第三级
        row_d3[3] <= row_d2[3]; col_d3[3] <= col_d2[3];
    end
end

// valid 信号延迟线 (4x4 阵列需要 3 级延迟)
reg [2:0] bar_valid_delay;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bar_valid_delay <= 3'b0;
    end else begin
        bar_valid_delay <= {bar_valid_delay[1:0], bar_valid};
    end
end

// [ ---------------------- 4x4 systolic array wiring ---------------------- ]
// 定义 PE 间的互连线，多定义一维用于边界
wire [7:0] row_wire [0:4][0:4];
wire [7:0] col_wire [0:4][0:4];
wire vld_wire [0:4][0:4];

// 输入边界赋值 (根据 add_mode 决定是否跳过延迟线)
assign row_wire[0][0] = row_in[0];
assign row_wire[1][0] = (add_mode) ? row_in[1] : row_d1[1];
assign row_wire[2][0] = (add_mode) ? row_in[2] : row_d2[2];
assign row_wire[3][0] = (add_mode) ? row_in[3] : row_d3[3];

assign col_wire[0][0] = col_in[0];
assign col_wire[0][1] = (add_mode) ? col_in[1] : col_d1[1];
assign col_wire[0][2] = (add_mode) ? col_in[2] : col_d2[2];
assign col_wire[0][3] = (add_mode) ? col_in[3] : col_d3[3];

assign vld_wire[0][0] = bar_valid;
assign vld_wire[1][0] = (add_mode) ? bar_valid : bar_valid_delay[0];
assign vld_wire[2][0] = (add_mode) ? bar_valid : bar_valid_delay[1];
assign vld_wire[3][0] = (add_mode) ? bar_valid : bar_valid_delay[2];

// [ ---------------------- PE Array Generation ---------------------- ]
generate 
    genvar i, j;
    for (i = 0; i < 4; i = i + 1) begin : row_gen
        for (j = 0; j < 4; j = j + 1) begin : col_gen
            pe #(
                .DOT_K(DOT_K)
            ) pe_inst(
                .clk(clk),
                .rst_n(rst_n),
                .flush(flush),
                .row_i(row_wire[i][j]),
                .col_i(col_wire[i][j]),
                .din_valid(vld_wire[i][j]),
                .signed_mode(signed_mode),
                .dot_k(dot_k),
                .row_o(row_wire[i][j+1]),
                .col_o(col_wire[i+1][j]),
                .dout_valid(vld_wire[i][j+1]),
                .res(pe_res[i][j]),
                .res_valid(pe_res_valid[i][j]),
                .add_mode(add_mode),
                .add_compute_valid(add_compute_valid)
            );
        end
    end
endgenerate

generate
    genvar m, n;
    for (m = 0; m < 4; m = m + 1) begin : out_row_gen
        for (n = 0; n < 4; n = n + 1) begin : out_col_gen
            assign pe_res_i8[m][n] = {pe_res[m][n][31], pe_res[m][n][out_shift +: 7]};
            assign biased_val[m][n] = {{24{pe_res_i8[m][n][7]}}, pe_res_i8[m][n]} + {{24{bias_vec[n*8+7]}}, bias_vec[n*8 +: 8]};
            assign pe_post_i8[m][n] = relu_en && (biased_val[m][n] <= 32'sd0)
                                    ? 8'sd0
                                    : sat_i8(biased_val[m][n]);
            assign res_valid[(m*4)+n] = pe_res_valid[m][n];
        end
    end
endgenerate

always_comb begin
    for (int rr = 0; rr < 4; rr++) begin
        for (int cc = 0; cc < 4; cc++) begin
            res[((rr*4+cc)*8) +: 8] = pe_post_i8[rr][cc];
        end
    end
end

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

endmodule
