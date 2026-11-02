`timescale 1ns / 1ps
// 等比铺满：统一源步长 step/den，先算居中裁切的整数起点与余数。
// 只在装载时执行一次逐位除法，不推入动态乘除法器。
module bmp_fit_geom #(
    parameter integer FRAME_W = 640,
    parameter integer FRAME_H = 480,
    parameter integer MAX_SOURCE_DIM = 65535
)(
    input wire clk, rst, start,
    input wire [15:0] img_w, img_h,
    output wire ready,
    output reg [15:0] step, den,
    output reg [15:0] x_start, y_start, x_phase, y_phase
);
localparam integer FRAME_MAX = FRAME_W > FRAME_H ? FRAME_W : FRAME_H;
localparam integer SOURCE_BITS = $clog2(MAX_SOURCE_DIM + 1);
localparam integer DEN_BITS = $clog2(FRAME_MAX + 1);
localparam integer NUM_BITS = $clog2(MAX_SOURCE_DIM * FRAME_MAX + 1);
localparam integer COUNT_BITS = $clog2(NUM_BITS + 1);
localparam [2:0] G_IDLE = 0, G_PICK = 1, G_DIV = 2, G_LATCH = 3, G_DONE = 4;
reg [2:0] state;
reg [NUM_BITS-1:0] width_height, height_width, numerator;
reg [SOURCE_BITS-1:0] quotient;
reg [DEN_BITS:0] remainder;
reg [COUNT_BITS-1:0] bits_left;
reg crop_x, ready_r;
reg [SOURCE_BITS-1:0] width_r, height_r;
wire [DEN_BITS:0] divisor = {1'b0, den[DEN_BITS-1:0]};
wire [DEN_BITS:0] trial = {remainder[DEN_BITS-1:0], numerator[NUM_BITS-1]};
wire subtract = trial >= divisor;
wire [DEN_BITS:0] next_remainder = subtract ? trial - divisor : trial;
assign ready = ready_r && !start;

function [NUM_BITS-1:0] multiply_constant;
    input [SOURCE_BITS-1:0] value;
    input integer constant_value;
    integer bit_index;
    begin
        multiply_constant = 0;
        for (bit_index = 0; bit_index < NUM_BITS; bit_index = bit_index + 1)
            if (constant_value[bit_index])
                multiply_constant = multiply_constant +
                                    ({{(NUM_BITS-SOURCE_BITS){1'b0}}, value} << bit_index);
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= G_IDLE;
        ready_r <= 0;
        step <= 0;
        den <= 0;
        x_start <= 0;
        y_start <= 0;
        x_phase <= 0;
        y_phase <= 0;
        width_height <= 0;
        height_width <= 0;
        numerator <= 0;
        width_r <= 0;
        height_r <= 0;
        quotient <= 0;
        remainder <= 0;
        bits_left <= 0;
        crop_x <= 0;
    end else if (start) begin
        width_height <= multiply_constant(img_w, FRAME_H);
        height_width <= multiply_constant(img_h, FRAME_W);
        width_r <= img_w;
        height_r <= img_h;
        ready_r <= 0;
        x_start <= 0;
        y_start <= 0;
        x_phase <= 0;
        y_phase <= 0;
        state <= G_PICK;
    end else case (state)
        G_PICK: begin
            crop_x <= width_height >= height_width;
            step <= (width_height >= height_width) ? height_r : width_r;
            den <= (width_height >= height_width) ? FRAME_H : FRAME_W;
            numerator <= (width_height >= height_width) ?
                         ((width_height - height_width) >> 1) :
                         ((height_width - width_height) >> 1);
            quotient <= 0;
            remainder <= 0;
            bits_left <= NUM_BITS;
            state <= G_DIV;
        end
        G_DIV: begin
            numerator <= numerator << 1;
            quotient <= (quotient << 1) | subtract;
            remainder <= next_remainder;
            bits_left <= bits_left - 1'b1;
            if (bits_left == 1) state <= G_LATCH;
        end
        G_LATCH: begin
            x_start <= crop_x ? quotient : 16'd0;
            y_start <= crop_x ? 16'd0 : quotient;
            x_phase <= crop_x ? remainder : 16'd0;
            y_phase <= crop_x ? 16'd0 : remainder;
            ready_r <= 1;
            state <= G_DONE;
        end
        G_IDLE, G_DONE: begin end
        default: state <= G_IDLE;
    endcase
end
endmodule
