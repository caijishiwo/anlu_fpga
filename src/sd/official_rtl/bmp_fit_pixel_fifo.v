`timescale 1ns / 1ps
// 24bit BMP 字节解包与扇区节流；保留源像素，行尾补位不入队。
// RAM 同步读，出队后下一拍有效；溢出锁存上报，禁止伪造成功。
module bmp_fit_pixel_fifo #(
    parameter integer FIFO_RSV = 256
)(
    input wire clk, rst, clear, active,
    input wire [15:0] img_w, img_h,
    input wire src_valid,
    input wire [7:0] src_byte,
    input wire pop,
    output reg [23:0] pixel,
    output wire empty, can_accept,
    output reg overflow
);
localparam integer ADDRESS_BITS = 9;
localparam integer DEPTH = 1 << ADDRESS_BITS;
reg [23:0] memory [0:DEPTH-1]; /* fehdl force_ram=1, ram_style="bram" */
reg [ADDRESS_BITS-1:0] write_address, read_address;
reg [ADDRESS_BITS:0] used;
reg [1:0] byte_index, padding;
reg [7:0] blue, green;
reg [15:0] source_x, source_y;
wire full = used == DEPTH;
wire push = active && src_valid && padding == 0 && byte_index == 2 &&
            source_y < img_h;
wire write_enable = push && !full && !clear;
wire read_enable = pop && !empty && !clear;
assign empty = used == 0;
assign can_accept = active && !overflow && used <= (DEPTH - FIFO_RSV);

always @(posedge clk) begin
    if (write_enable)
        memory[write_address] <= {src_byte, green, blue};
    pixel <= memory[read_address];
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        write_address <= 0;
        read_address <= 0;
        used <= 0;
        overflow <= 0;
    end else if (clear) begin
        write_address <= 0;
        read_address <= 0;
        used <= 0;
        overflow <= 0;
    end else begin
        if (write_enable) write_address <= write_address + 1'b1;
        if (read_enable) read_address <= read_address + 1'b1;
        case ({write_enable, read_enable})
            2'b10: used <= used + 1'b1;
            2'b01: used <= used - 1'b1;
            default: begin end
        endcase
        if (push && full) overflow <= 1;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        byte_index <= 0;
        padding <= 0;
        blue <= 0;
        green <= 0;
        source_x <= 0;
        source_y <= 0;
    end else if (clear) begin
        byte_index <= 0;
        padding <= 0;
        source_x <= 0;
        source_y <= 0;
    end else if (active && src_valid && source_y < img_h) begin
        if (padding != 0) padding <= padding - 1'b1;
        else case (byte_index)
            0: begin blue <= src_byte; byte_index <= 1; end
            1: begin green <= src_byte; byte_index <= 2; end
            2: begin
                byte_index <= 0;
                if (source_x + 1'b1 == img_w) begin
                    source_x <= 0;
                    source_y <= source_y + 1'b1;
                    padding <= img_w[1:0];
                end else source_x <= source_x + 1'b1;
            end
            default: byte_index <= 0;
        endcase
    end
end
endmodule
