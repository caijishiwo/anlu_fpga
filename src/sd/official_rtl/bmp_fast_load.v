`timescale 1ns/1ps
// 校验BMP头并启动按需取样；不会改写原图，也不会对失败的扇区伪造像素。
module bmp_fast_load(
 input wire clk,rst,start,abort,
 input wire [31:0] first_sector,
 output wire ready,
 output reg write_req,
 input wire write_req_ack,
 output wire sd_req,
 output wire [31:0] sd_address,
 input wire [7:0] sd_data,
 input wire sd_valid,sd_end,
 output wire out_valid,
 output wire [23:0] out_pixel,
 output reg failed,
 output wire [15:0] read_count
);
localparam IDLE=0,HEADER_REQ=1,HEADER_WAIT=2,VALIDATE=3,ACK=4,RUN=5;
localparam [22:0] MAX_BYTES=23'd4194304;
localparam BYTE_ADDRESS_BITS=$clog2(MAX_BYTES);
localparam [5:0] MIN_OFFSET=6'd54;
localparam [12:0] MAX_DIMENSION=13'd4096;
reg [2:0] state;
reg [5:0] header_index;
reg [22:0] file_bytes,pixel_offset;
reg [12:0] width,height;
reg header_invalid,invalid_byte;
reg sample_start,cache_abort;
wire cache_idle,cache_failed,cache_valid,sample_req,sample_done;
wire [7:0] cache_data;
wire [31:0] sample_address;
wire header_phase=state==HEADER_REQ || state==HEADER_WAIT;
// 先用完整地址校验文件边界，再向缓存传递规格内的字节地址。
wire [BYTE_ADDRESS_BITS-1:0] cache_address=header_phase ? header_index :
 sample_address[BYTE_ADDRESS_BITS-1:0];
wire cache_request=state==HEADER_REQ || (state==RUN && sample_req && sample_address<file_bytes);
wire header_ok=!header_invalid &&
 width>=1 && width<=MAX_DIMENSION && height>=1 && height<=MAX_DIMENSION &&
 pixel_offset>=MIN_OFFSET && pixel_offset<file_bytes && file_bytes<=MAX_BYTES;
assign ready=state==IDLE && cache_idle;
bmp_byte_cache #(.ADDRESS_BITS(BYTE_ADDRESS_BITS)) cache(
 .clk(clk),.rst(rst),.clear(start || abort || cache_abort),
 .first_sector(first_sector),.byte_address(cache_address),.byte_req(cache_request),
 .byte_valid(cache_valid),.byte_data(cache_data),.idle(cache_idle),.failed(cache_failed),
 .sd_req(sd_req),.sd_address(sd_address),.sd_data(sd_data),.sd_valid(sd_valid),
 .sd_end(sd_end),.read_count(read_count));
bmp_sample_pixels sampler(.clk(clk),.rst(rst),.start(sample_start),
 .abort(abort || cache_abort),.img_w({3'd0,width}),.img_h({3'd0,height}),
 .pixel_offset({9'd0,pixel_offset}),.byte_req(sample_req),.byte_address(sample_address),
 .byte_valid(cache_valid && state==RUN),.byte_data(cache_data),
 .out_valid(out_valid),.out_pixel(out_pixel),.done(sample_done));
// 丢弃的高位逐字节验证，不能把负尺寸或超限偏移截成合法数值。
always @* begin
 case(header_index)
  0:invalid_byte=cache_data!=8'h42;
  1:invalid_byte=cache_data!=8'h4d;
  4,12:invalid_byte=cache_data[7];
  19,23:invalid_byte=|cache_data[7:5];
  28:invalid_byte=cache_data!=8'd24;
  5,13,20,21,24,25,29,30,31,32,33:invalid_byte=cache_data!=0;
  default:invalid_byte=0;
 endcase
end
always @(posedge clk or posedge rst) begin
 if(rst) begin
  file_bytes<=0;pixel_offset<=0;width<=0;height<=0;header_invalid<=0;
 end else if(start) header_invalid<=0;
 else if(state==HEADER_WAIT && cache_valid) begin
  header_invalid<=header_invalid || invalid_byte;
  case(header_index)
   2:file_bytes[7:0]<=cache_data;3:file_bytes[15:8]<=cache_data;
   4:file_bytes[22:16]<=cache_data[6:0];
   10:pixel_offset[7:0]<=cache_data;11:pixel_offset[15:8]<=cache_data;
   12:pixel_offset[22:16]<=cache_data[6:0];
   18:width[7:0]<=cache_data;19:width[12:8]<=cache_data[4:0];
   22:height[7:0]<=cache_data;23:height[12:8]<=cache_data[4:0];
   default:begin end
  endcase
 end
end
always @(posedge clk or posedge rst) begin
 if(rst) begin state<=IDLE;header_index<=0;write_req<=0;failed<=0;sample_start<=0;cache_abort<=0;end
 else begin
  sample_start<=0;cache_abort<=0;
  if(abort) begin state<=IDLE;write_req<=0;end
  else if(cache_failed || (state==RUN && sample_req && sample_address>=file_bytes)) begin
   state<=IDLE;failed<=1;write_req<=0;cache_abort<=1;
  end else case(state)
   IDLE: if(start && cache_idle) begin header_index<=0;failed<=0;state<=HEADER_REQ;end
   HEADER_REQ: state<=HEADER_WAIT;
   HEADER_WAIT: if(cache_valid) begin
    if(header_index==MIN_OFFSET-1) state<=VALIDATE;
    else begin header_index<=header_index+1'b1;state<=HEADER_REQ;end
   end
   VALIDATE: if(header_ok) begin write_req<=1;state<=ACK;end
    else begin failed<=1;state<=IDLE;end
   ACK: if(write_req_ack) begin write_req<=0;sample_start<=1;state<=RUN;end
   RUN: if(sample_done) state<=IDLE;
   default: state<=IDLE;
  endcase
 end
end
endmodule
