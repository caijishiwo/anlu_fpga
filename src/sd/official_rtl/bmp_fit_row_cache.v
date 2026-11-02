`timescale 1ns / 1ps
// 使用TD官方32K RAM原语保存24bit输出行，避免工具将640深度数组展开成触发器。
// 无输出附加寄存器：时钟上升沿读取，延迟与缩放状态机的同步读契约一致。
module bmp_fit_row_cache (
    input wire clk, write_enable,
    input wire [10:0] address,
    input wire [23:0] write_data,
    output wire [23:0] read_data
);
wire [15:0] low_data, high_data;
assign read_data = {high_data[7:0], low_data};
EG_PHY_BRAM32K #(
    .DATA_WIDTH_A("16"), .DATA_WIDTH_B("16"),
    .REGMODE_A("NOREG"), .REGMODE_B("NOREG")
) u_low (
    .clka(clk), .clkb(clk), .addra(address), .addrb(address),
    .dia(write_data[15:0]), .dib(16'd0), .doa(), .dob(low_data),
    .csa(write_enable), .csb(1'b1), .wea(1'b1), .web(1'b0),
    .bytea(1'b0), .byteb(1'b0), .bytewea(1'b0), .byteweb(1'b0),
    .rsta(1'b0), .rstb(1'b0), .ocea(1'b1), .oceb(1'b1)
);
EG_PHY_BRAM32K #(
    .DATA_WIDTH_A("16"), .DATA_WIDTH_B("16"),
    .REGMODE_A("NOREG"), .REGMODE_B("NOREG")
) u_high (
    .clka(clk), .clkb(clk), .addra(address), .addrb(address),
    .dia({8'd0, write_data[23:16]}), .dib(16'd0), .doa(), .dob(high_data),
    .csa(write_enable), .csb(1'b1), .wea(1'b1), .web(1'b0),
    .bytea(1'b0), .byteb(1'b0), .bytewea(1'b0), .byteweb(1'b0),
    .rsta(1'b0), .rstb(1'b0), .ocea(1'b1), .oceb(1'b1)
);
endmodule
