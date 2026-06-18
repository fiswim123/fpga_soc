`timescale 1ns / 1ps

module ram #(
    parameter int DEPTH = 1024,
    parameter int AW = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter int DW = 32,
    parameter string INIT_FILE = ""
)(
    input  logic clk,

    input  logic wr_en,
    input  logic [AW-1:0] wr_addr,
    input  logic [DW-1:0] wr_data,

    input  logic rd_en,
    input  logic [AW-1:0] rd_addr,
    output logic [DW-1:0] rd_data
);

    (* ram_style = "block" *) logic [DW-1:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
        if (rd_en) begin
            rd_data <= mem[rd_addr];
        end
    end

endmodule
