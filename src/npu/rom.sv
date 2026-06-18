`timescale 1ns / 1ps

module rom #(
    parameter                           FILE                        = "param_init.dat"  ,
    parameter                           AW                          = 32                   ,
    parameter                           DW                          = 8                    ,
    parameter                           ROM_DEPTH                   = 4096  
    )(
    input  logic                        clk                        ,
    input  logic                        rst_n                      ,
    input  logic         [AW-1: 0]      instr_addr                 ,
    output logic         [DW-1: 0]      instr_out                   
);

    (* ram_style = "block" *) logic [DW-1:0] rom_mem [0:ROM_DEPTH-1];

initial begin
    $readmemh(FILE, rom_mem);
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        instr_out <= '0;
    end else begin
        // Synchronous read lets FPGA tools infer BRAM instead of registers/LUTs.
        instr_out <= rom_mem[instr_addr];
    end
end
		
endmodule
