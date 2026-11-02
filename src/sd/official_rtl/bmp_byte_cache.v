`timescale 1ns/1ps
// 一份512字节同步RAM；仅在所需扇区变化时读卡。中止须先排空在途扇区。
module bmp_byte_cache #(parameter ADDRESS_BITS=32)(
 input wire clk,rst,clear,
 input wire [31:0] first_sector,
 input wire [ADDRESS_BITS-1:0] byte_address,
 input wire byte_req,
 output wire byte_valid,
 output wire [7:0] byte_data,
 output wire idle,
 output reg failed,
 output wire sd_req,
 output reg [31:0] sd_address,
 input wire [7:0] sd_data,
 input wire sd_valid,sd_end,
 output reg [15:0] read_count
);
localparam IDLE=0,LOOK=1,FILL=2,REPLY=3,DRAIN=4;
localparam SECTOR_BYTES=512,SECTOR_BITS=$clog2(SECTOR_BYTES);
localparam TAG_BITS=ADDRESS_BITS-SECTOR_BITS;
reg [2:0] state;
reg [7:0] memory[0:SECTOR_BYTES-1]; /* fehdl force_ram=1, ram_style="bram" */
reg [7:0] memory_data;
reg [8:0] offset;
reg [TAG_BITS-1:0] tag;
reg cached;
reg [9:0] received;
wire complete_sector=(received==SECTOR_BYTES && !sd_valid) ||
                     (received==SECTOR_BYTES-1 && sd_valid);
assign idle=state==IDLE;
assign byte_valid=state==REPLY;
assign byte_data=memory_data;
assign sd_req=state==FILL || state==DRAIN;
always @(posedge clk) begin
 if(state==FILL && sd_valid && received<SECTOR_BYTES)
  memory[received[8:0]]<=sd_data;
 memory_data<=memory[offset];
end
always @(posedge clk or posedge rst) begin
 if(rst) read_count<=0;
 else if(sd_req && sd_end) read_count<=read_count+1'b1;
end
always @(posedge clk or posedge rst) begin
 if(rst) begin
  state<=IDLE;offset<=0;tag<=0;cached<=0;
  received<=0;failed<=0;sd_address<=0;
 end else if(clear) begin
  cached<=0;failed<=0;
  state<=((state==FILL || state==DRAIN) && !sd_end) ? DRAIN : IDLE;
 end else case(state)
  IDLE: if(byte_req) begin
   offset<=byte_address[8:0];
   if(cached && tag==byte_address[ADDRESS_BITS-1:SECTOR_BITS]) state<=LOOK;
   else begin
    tag<=byte_address[ADDRESS_BITS-1:SECTOR_BITS];cached<=0;
    sd_address<=first_sector+{{(32-TAG_BITS){1'b0}},byte_address[ADDRESS_BITS-1:SECTOR_BITS]};
    received<=0;state<=FILL;
   end
  end
  LOOK: state<=REPLY;
  FILL: begin
   if(sd_valid && received<=SECTOR_BYTES) received<=received+1'b1;
   if(sd_end) begin
    if(complete_sector) begin cached<=1;state<=LOOK;end
    else begin failed<=1;cached<=0;state<=IDLE;end
   end
  end
  REPLY: state<=IDLE;
  DRAIN: if(sd_end) state<=IDLE;
  default: state<=IDLE;
 endcase
end
endmodule
