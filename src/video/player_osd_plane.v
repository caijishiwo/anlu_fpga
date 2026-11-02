`timescale 1ns/1ps
// 384x320 I1显存：小块OSD与歌词页文字共享，所有区域同一拍同步读。
module player_osd_plane (
    input wire clk,write_en,
    input wire [11:0] write_addr,
    input wire [31:0] write_data,
    input wire enabled,page,menu,player,lyrics_view,
    input wire [2:0] selected,
    input wire [9:0] x,y,
    output wire hit,pixel,muted,
    output reg accent
);
reg [31:0] words [0:4095] /* fehdl force_ram=1, ram_style="bram" */;
localparam integer PANEL_X=20,PANEL_Y=20,NAV_WIDTH=160,NAV_HEIGHT=228;
localparam integer DETAIL_WIDTH=224,DETAIL_HEIGHT=200,CORNER=4;
wire information=player && lyrics_view;
wire title=information && x>=64 && x<256 && y>=218 && y<242;
wire cue=information && x>=96 && x<224 && y>=246 && y<270;
wire heading=information && x>=28 && x<124 && y>=24 && y<48;
wire elapsed=information && x>=60 && x<124 && y>=431 && y<455;
wire duration=information && x>=532 && x<612 && y>=431 && y<455;
wire progress=information && x>=128 && x<512 && y==438;
wire counter=!lyrics_view && x>=488 && x<616 && y>=20 && y<44;
wire [9:0] local_x=x-PANEL_X,local_y=y-PANEL_Y;
wire [9:0] panel_width=page ? DETAIL_WIDTH : NAV_WIDTH;
wire [9:0] panel_height=page ? DETAIL_HEIGHT : NAV_HEIGHT;
wire [9:0] edge_x=local_x<panel_width/2 ? local_x : panel_width-1-local_x;
wire [9:0] edge_y=local_y<panel_height/2 ? local_y : panel_height-1-local_y;
wire panel=menu && x>=PANEL_X && y>=PANEL_Y &&
    local_x<panel_width && local_y<panel_height && edge_x+edge_y>=CORNER;
wire [9:0] column=panel ? (page ? local_x : local_x+10'd224) :
    (title ? x-10'd64 : (cue ? x-10'd96 : (heading ? x-10'd28 :
    (elapsed ? x+10'd68 : (duration ? x-10'd404 :
    (counter ? x-10'd488 : ((x-10'd128)>>2)))))));
wire [9:0] row=panel ? (page ? local_y+10'd112 : local_y) :
    (title ? y-10'd218 : (cue ? y-10'd222 : (heading ? y+10'd56 :
    (elapsed ? y-10'd407 : (duration ? y-10'd375 :
    (counter ? y+10'd36 : 10'd104))))));
wire [11:0] read_addr=(row<<3)+(row<<2)+{7'b0,column[9:5]};
wire [4:0] read_bit={column[4:3],~column[2:0]};
reg [31:0] read_word;
reg [4:0] bit_d;
reg panel_d,text_d,cue_d,progress_d;
wire [9:0] selected_y=10'd39+{2'b0,selected,5'b0};
always @(posedge clk) begin
    if(write_en) words[write_addr]<=write_data;
    read_word<=words[read_addr];bit_d<=read_bit;
    panel_d<=enabled && panel;
    text_d<=enabled && !panel && (title || cue || heading || elapsed || duration || counter);
    cue_d<=enabled && !panel && cue;
    progress_d<=enabled && !panel && progress;
    accent<=enabled && panel && !page && local_x>=8 && local_x<NAV_WIDTH-8 &&
        local_y>=selected_y && local_y<selected_y+32;
end
assign pixel=read_word[bit_d];
assign hit=panel_d || progress_d || (text_d && pixel);
assign muted=cue_d || (progress_d && !pixel);
endmodule
