`timescale 1ns/1ps
// 8704字/窗口，双缓冲共17408字，使用9块官方32K RAM。
module lyric_window_cache(
    input wire write_clk,read_clk,write_enable,write_bank,read_bank,
    input wire [13:0] write_address,read_address,
    input wire [15:0] write_data,
    output wire [15:0] read_data
);
localparam [14:0] WINDOW_WORDS=15'd8704;
wire [14:0] write_physical={1'b0,write_address}+(write_bank ? WINDOW_WORDS : 15'd0);
wire [14:0] read_physical={1'b0,read_address}+(read_bank ? WINDOW_WORDS : 15'd0);
wire [143:0] block_data;
reg [3:0] block_d;
always @(posedge read_clk) block_d<=read_physical[14:11];
assign read_data=block_data[block_d*16+:16];
genvar block_index;
generate for(block_index=0;block_index<9;block_index=block_index+1) begin:g_block
    EG_PHY_BRAM32K #(.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG")) u_ram(
        .clka(write_clk),.clkb(read_clk),.addra(write_physical[10:0]),
        .addrb(read_physical[10:0]),.dia(write_data),.dib(16'd0),
        .doa(),.dob(block_data[block_index*16+:16]),
        .csa(write_enable && write_physical[14:11]==block_index),
        .csb(read_physical[14:11]==block_index),.wea(1'b1),.web(1'b0),
        .bytea(1'b0),.byteb(1'b0),.bytewea(1'b0),.byteweb(1'b0),
        .rsta(1'b0),.rstb(1'b0),.ocea(1'b1),.oceb(1'b1));
end endgenerate
endmodule
