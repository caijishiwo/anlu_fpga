`timescale 1ns / 1ps
// 任意已支持的24bit BMP -> 等比铺满固定帧，最近邻采样并居中裁切。
// 横纵使用同一个 step/den，重复源行从输出行缓存复用；整帧无补黑分支。
module bmp_fit_stream #(
    parameter integer FRAME_W = 640,
    parameter integer FRAME_H = 480,
    parameter integer FIFO_RSV = 256,
    parameter integer PIX_DIV = 8
)(
    input wire clk, rst, start, abort,
    input wire [15:0] img_w, img_h,
    input wire src_valid,
    input wire [7:0] src_byte,
    output reg out_valid,
    output reg [23:0] out_data,
    output reg busy, frame_done,
    output wire starving, fifo_ovf,
    output reg [31:0] pix_cnt,
    output reg [15:0] out_w_dbg, out_h_dbg,
    output wire can_accept
);
localparam integer GATE_BITS = (PIX_DIV > 1) ? $clog2(PIX_DIV) : 1;
localparam [3:0] C_IDLE = 0, C_GEOM = 1, C_ROW = 2, C_PIXEL = 3;
localparam [3:0] C_TAKE = 4, C_EMIT = 5, C_XSTEP = 6, C_XADV = 7;
localparam [3:0] C_TAIL = 8, C_YSTEP = 9, C_YADV = 10;
localparam [3:0] C_REPEAT_WAIT = 11, C_REPEAT = 12, C_DROP_ROW = 13;
reg [3:0] state;
reg [15:0] source_w, source_h, source_x, source_y;
reg [15:0] target_x, target_y, initial_x, initial_phase;
reg [15:0] acc_x, acc_y, step_r, den_r;
reg [15:0] ox, oy;
reg [23:0] sampled_pixel;
reg [GATE_BITS-1:0] gate_count;
wire emit_ok = gate_count == 0;
wire accepted_start = start && state == C_IDLE && !abort;
wire clear = accepted_start || abort;
wire geometry_ready;
wire [15:0] geometry_step, geometry_den;
wire [15:0] geometry_x, geometry_y, geometry_x_phase, geometry_y_phase;
wire [23:0] fifo_pixel;
wire fifo_empty, fifo_pop;
assign fifo_pop = !abort && !fifo_empty &&
                  (state == C_PIXEL || state == C_DROP_ROW ||
                   (state == C_TAIL && source_x < source_w));
assign starving = busy && fifo_empty &&
                  (state == C_PIXEL || state == C_DROP_ROW ||
                   (state == C_TAIL && source_x < source_w));

bmp_fit_geom #(.FRAME_W(FRAME_W), .FRAME_H(FRAME_H)) u_geom (
    .clk(clk), .rst(rst), .start(accepted_start), .img_w(img_w), .img_h(img_h),
    .ready(geometry_ready), .step(geometry_step), .den(geometry_den),
    .x_start(geometry_x), .y_start(geometry_y),
    .x_phase(geometry_x_phase), .y_phase(geometry_y_phase)
);
bmp_fit_pixel_fifo #(.FIFO_RSV(FIFO_RSV)) u_fifo (
    .clk(clk), .rst(rst), .clear(clear), .active(busy),
    .img_w(source_w), .img_h(source_h), .src_valid(src_valid), .src_byte(src_byte),
    .pop(fifo_pop), .pixel(fifo_pixel), .empty(fifo_empty),
    .can_accept(can_accept), .overflow(fifo_ovf)
);

wire [23:0] row_pixel;
bmp_fit_row_cache u_row_cache (
    .clk(clk), .address(ox[10:0]), .write_data(sampled_pixel), .read_data(row_pixel),
    .write_enable(state == C_EMIT && emit_ok && !abort)
);

always @(posedge clk or posedge rst) begin
    if (rst) gate_count <= 0;
    else gate_count <= (gate_count == PIX_DIV - 1) ? 0 : gate_count + 1'b1;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= C_IDLE;
        out_valid <= 0;
        out_data <= 0;
        busy <= 0;
        frame_done <= 0;
        pix_cnt <= 0;
        out_w_dbg <= 0;
        out_h_dbg <= 0;
        source_w <= 0;
        source_h <= 0;
        source_x <= 0;
        source_y <= 0;
        target_x <= 0;
        target_y <= 0;
        initial_x <= 0;
        initial_phase <= 0;
        acc_x <= 0;
        acc_y <= 0;
        step_r <= 0;
        den_r <= 0;
        ox <= 0;
        oy <= 0;
        sampled_pixel <= 0;
    end else begin
        out_valid <= 0;
        if (abort) begin
            state <= C_IDLE;
            busy <= 0;
            frame_done <= 0;
        end else case (state)
            C_IDLE: begin
                if (accepted_start) begin
                    source_w <= img_w;
                    source_h <= img_h;
                    source_x <= 0;
                    source_y <= 0;
                    ox <= 0;
                    oy <= 0;
                    pix_cnt <= 0;
                    frame_done <= 0;
                    busy <= 1;
                    state <= C_GEOM;
                end
            end
            C_GEOM: begin
                if (geometry_ready) begin
                    step_r <= geometry_step;
                    den_r <= geometry_den;
                    initial_x <= geometry_x;
                    initial_phase <= geometry_x_phase;
                    target_y <= geometry_y;
                    acc_y <= geometry_y_phase;
                    out_w_dbg <= FRAME_W;
                    out_h_dbg <= FRAME_H;
                    state <= C_ROW;
                end
            end
            C_ROW: begin
                if (source_y < target_y) state <= C_DROP_ROW;
                else begin
                    target_x <= initial_x;
                    acc_x <= initial_phase;
                    source_x <= 0;
                    ox <= 0;
                    state <= C_PIXEL;
                end
            end
            C_DROP_ROW: begin
                if (fifo_pop) begin
                    if (source_x + 1'b1 == source_w) begin
                        source_x <= 0;
                        source_y <= source_y + 1'b1;
                        state <= C_ROW;
                    end else source_x <= source_x + 1'b1;
                end
            end
            C_PIXEL: begin
                if (fifo_pop) begin
                    source_x <= source_x + 1'b1;
                    if (source_x == target_x) state <= C_TAKE;
                end
            end
            C_TAKE: begin
                sampled_pixel <= fifo_pixel;
                state <= C_EMIT;
            end
            C_EMIT: begin
                if (emit_ok) begin
                    out_valid <= 1;
                    out_data <= sampled_pixel;
                    pix_cnt <= pix_cnt + 1'b1;
                    if (ox + 1'b1 == FRAME_W) begin
                        ox <= 0;
                        oy <= oy + 1'b1;
                        state <= C_TAIL;
                    end else begin
                        ox <= ox + 1'b1;
                        state <= C_XSTEP;
                    end
                end
            end
            C_XSTEP: begin
                acc_x <= acc_x + step_r;
                state <= C_XADV;
            end
            C_XADV: begin
                if (acc_x >= den_r) begin
                    acc_x <= acc_x - den_r;
                    target_x <= target_x + 1'b1;
                end else state <= (target_x + 1'b1 == source_x) ? C_EMIT : C_PIXEL;
            end
            C_TAIL: begin
                if (source_x == source_w) begin
                    source_x <= 0;
                    source_y <= source_y + 1'b1;
                    state <= C_YSTEP;
                end else if (fifo_pop) source_x <= source_x + 1'b1;
            end
            C_YSTEP: begin
                if (oy == FRAME_H) begin
                    busy <= 0;
                    frame_done <= 1;
                    state <= C_IDLE;
                end else begin
                    acc_y <= acc_y + step_r;
                    state <= C_YADV;
                end
            end
            C_YADV: begin
                if (acc_y >= den_r) begin
                    acc_y <= acc_y - den_r;
                    target_y <= target_y + 1'b1;
                end else begin
                    ox <= 0;
                    state <= (target_y < source_y) ? C_REPEAT_WAIT : C_ROW;
                end
            end
            C_REPEAT_WAIT: state <= C_REPEAT; // ox改变后等待一次同步RAM读取。
            C_REPEAT: begin
                if (emit_ok) begin
                    out_valid <= 1;
                    out_data <= row_pixel;
                    pix_cnt <= pix_cnt + 1'b1;
                    if (ox + 1'b1 == FRAME_W) begin
                        ox <= 0;
                        oy <= oy + 1'b1;
                        state <= C_YSTEP;
                    end else begin
                        ox <= ox + 1'b1;
                        state <= C_REPEAT_WAIT;
                    end
                end
            end
            default: state <= C_IDLE;
        endcase
    end
end
endmodule
