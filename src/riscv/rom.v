`timescale 1ns / 1ps
// On-chip boot ROM: 256 x 32-bit words (1 KiB).
module rom ( doa, addra, clka, rsta );
    output reg [31:0] doa;
    input  [7:0]      addra;
    input             clka;
    input             rsta;
    reg [31:0] mem [0:255];   /* fehdl force_ram=1, ram_style="bram" */
    initial $readmemh("rt-thread.hex", mem);
    always @(posedge clka or posedge rsta) begin
        if (rsta) doa <= 32'd0;
        else      doa <= mem[addra];
    end
endmodule
