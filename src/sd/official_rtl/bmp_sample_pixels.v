`timescale 1ns/1ps
// 沿用原最近邻取样坐标；直接请求所需BGR字节，不读取被缩放丢弃的行。
module bmp_sample_pixels #(
 parameter FRAME_W=640,FRAME_H=480,PIX_DIV=8
)(
 input wire clk,rst,start,abort,
 input wire [15:0] img_w,img_h,
 input wire [31:0] pixel_offset,
 output wire byte_req,
 output wire [31:0] byte_address,
 input wire byte_valid,
 input wire [7:0] byte_data,
 output reg out_valid,
 output reg [23:0] out_pixel,
 output wire done
);
localparam IDLE=0,GEOMETRY=1,ROW=2,ISSUE=3,WAIT_BYTE=4,EMIT=5;
localparam X_PRE=6,X_ADV=7,Y_PRE=8,Y_ADV=9,REPEAT_WAIT=10,REPEAT_ROW=11,FINISH=12;
localparam GATE_BITS=PIX_DIV>1 ? $clog2(PIX_DIV) : 1;
localparam MAX_SOURCE_DIM=4096,SOURCE_BITS=$clog2(MAX_SOURCE_DIM+1);
localparam MAX_FRAME_DIM=FRAME_W>FRAME_H ? FRAME_W : FRAME_H;
localparam DEN_BITS=$clog2(MAX_FRAME_DIM+1),ACC_BITS=$clog2(MAX_SOURCE_DIM+MAX_FRAME_DIM);
localparam COL_BITS=$clog2(FRAME_W+1),ROW_BITS=$clog2(FRAME_H+1);
localparam STRIDE_BITS=$clog2(MAX_SOURCE_DIM*3+1);
localparam MAX_FILE_BYTES=4194304;
localparam ADDRESS_BITS=$clog2(MAX_SOURCE_DIM*MAX_SOURCE_DIM*3+MAX_FILE_BYTES);
reg [3:0] state;
reg [SOURCE_BITS-1:0] source_y,target_y;
reg [ACC_BITS-1:0] acc_x,acc_y;
reg [COL_BITS-1:0] ox;
reg [ROW_BITS-1:0] oy;
reg [STRIDE_BITS-1:0] stride,initial_x_bytes;
// 连同损坏文件的完整像素矩阵也能容纳，越界偏移不会回卷成有效请求。
reg [ADDRESS_BITS-1:0] row_base,sample_address;
reg [1:0] component;
reg [23:0] sampled_pixel;
reg advanced;
reg [GATE_BITS-1:0] gate_count;
wire emit_ok=gate_count==0;
wire geometry_ready;
wire [15:0] step,den,x_start,y_start,x_phase,y_phase;
// 几何输出一直保持到下次start，复用它们即可，无须重复保存步长和相位。
wire [SOURCE_BITS-1:0] source_step=step[SOURCE_BITS-1:0];
wire [DEN_BITS-1:0] denominator=den[DEN_BITS-1:0];
wire [23:0] row_pixel;
assign done=state==FINISH;
assign byte_req=state==ISSUE && !abort;
assign byte_address={{(32-ADDRESS_BITS){1'b0}},sample_address}+{30'd0,component};
bmp_fit_geom #(.FRAME_W(FRAME_W),.FRAME_H(FRAME_H),.MAX_SOURCE_DIM(MAX_SOURCE_DIM)) geometry(
 .clk(clk),.rst(rst),.start(start),.img_w(img_w),.img_h(img_h),
 .ready(geometry_ready),.step(step),.den(den),.x_start(x_start),.y_start(y_start),
 .x_phase(x_phase),.y_phase(y_phase));
bmp_fit_row_cache row_cache(.clk(clk),.address({1'b0,ox[9:0]}),
 .write_data(sampled_pixel),.read_data(row_pixel),
 .write_enable(state==EMIT && emit_ok && !abort));
always @(posedge clk or posedge rst) begin
 if(rst) gate_count<=0;
 else gate_count<=gate_count==PIX_DIV-1 ? 0 : gate_count+1'b1;
end
always @(posedge clk or posedge rst) begin
 if(rst) begin
  state<=IDLE;out_valid<=0;out_pixel<=0;
  source_y<=0;target_y<=0;ox<=0;oy<=0;acc_x<=0;acc_y<=0;
  stride<=0;row_base<=0;sample_address<=0;initial_x_bytes<=0;
  component<=0;sampled_pixel<=0;advanced<=0;
 end else begin
  out_valid<=0;
  if(abort) state<=IDLE;
  else if(start) begin
   state<=GEOMETRY;row_base<=pixel_offset;source_y<=0;ox<=0;oy<=0;
   stride<=(({16'd0,img_w}<<1)+{16'd0,img_w}+32'd3) & 32'hfffffffc;
  end else case(state)
   GEOMETRY: if(geometry_ready) begin
    target_y<=y_start;acc_y<=y_phase;
    initial_x_bytes<=({16'd0,x_start}<<1)+{16'd0,x_start};
    state<=ROW;
   end
   ROW: if(source_y<target_y) begin source_y<=source_y+1'b1;row_base<=row_base+stride;end
    else begin
     sample_address<=row_base+initial_x_bytes;acc_x<=x_phase[DEN_BITS-1:0];
     ox<=0;component<=0;state<=ISSUE;
    end
   ISSUE: state<=WAIT_BYTE;
   WAIT_BYTE: if(byte_valid) begin
    if(component==0) sampled_pixel[7:0]<=byte_data;
    if(component==1) sampled_pixel[15:8]<=byte_data;
    if(component==2) begin sampled_pixel[23:16]<=byte_data;component<=0;state<=EMIT;end
    else begin component<=component+1'b1;state<=ISSUE;end
   end
   EMIT: if(emit_ok) begin
    out_valid<=1;out_pixel<=sampled_pixel;
    if(ox==FRAME_W-1) begin ox<=0;oy<=oy+1'b1;state<=oy==FRAME_H-1 ? FINISH : Y_PRE;end
    else begin ox<=ox+1'b1;state<=X_PRE;end
   end
   X_PRE: begin acc_x<=acc_x+source_step;advanced<=0;state<=X_ADV;end
   X_ADV: if(acc_x>=denominator) begin
    acc_x<=acc_x-denominator;sample_address<=sample_address+32'd3;advanced<=1;
   end else state<=advanced ? ISSUE : EMIT;
   Y_PRE: begin acc_y<=acc_y+source_step;advanced<=0;state<=Y_ADV;end
   Y_ADV: if(acc_y>=denominator) begin acc_y<=acc_y-denominator;target_y<=target_y+1'b1;advanced<=1;end
    else begin ox<=0;state<=advanced ? ROW : REPEAT_WAIT;end
   REPEAT_WAIT: state<=REPEAT_ROW;
   REPEAT_ROW: if(emit_ok) begin
    out_valid<=1;out_pixel<=row_pixel;
    if(ox==FRAME_W-1) begin ox<=0;oy<=oy+1'b1;state<=oy==FRAME_H-1 ? FINISH : Y_PRE;end
    else begin ox<=ox+1'b1;state<=REPEAT_WAIT;end
   end
   IDLE,FINISH: begin end
   default: state<=IDLE;
  endcase
 end
end
endmodule
