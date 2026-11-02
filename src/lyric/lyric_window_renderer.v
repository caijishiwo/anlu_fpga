`timescale 1ns/1ps
// 原生字号与A2覆盖率；仅在场同步接受整组字形，禁止硬放大。
module lyric_window_renderer(
    input wire clk,rst,vs,enabled,lyrics_view,configured,window_ready,published,smooth_format,
    input wire [3:0] line_mask,
    input wire [43:0] left_bounds,right_bounds,
    input wire [7:0] published_line,
    input wire [9:0] x,y,
    input wire [15:0] read_data,
    output reg read_bank,
    output wire [13:0] read_address,
    output wire band_on,text_on,
    output wire [23:0] text_rgb,
    output wire [1:0] text_alpha
);
localparam [9:0] PHOTO_LEFT=24,PHOTO_WIDTH=592,PHOTO_TOP=428;
localparam [9:0] LYRIC_LEFT=300,LYRIC_WIDTH=316,PREVIOUS_TOP=172,
    CURRENT_TOP=220,NEXT_TOP=276,CLIP_TOP=140,CLIP_BOTTOM=332;
localparam [23:0] IVORY=24'hE8E6DE,MUTED=24'h777A74;
localparam signed [7:0] SCROLL_DISTANCE=56,SCROLL_STEP=7;
reg configured_m,configured_v,ready_m,ready_v,published_m,published_v,vs_d,format_v;
reg [3:0] mask_v;
reg [43:0] left_v,right_v;
reg [7:0] line_v;
reg signed [7:0] slide;
reg [10:0] pan;
reg pan_reverse;
reg [2:0] pan_timer;
wire [10:0] pan_limit;
wire frame_start=vs && !vs_d;
wire accept_window=frame_start && configured_v && ready_v && published_v!=read_bank;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        configured_m<=0;configured_v<=0;ready_m<=0;ready_v<=0;
        published_m<=0;published_v<=0;vs_d<=0;
    end else begin
        configured_m<=configured;configured_v<=configured_m;
        ready_m<=window_ready;ready_v<=ready_m;
        published_m<=published;published_v<=published_m;vs_d<=vs;
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        read_bank<=0;mask_v<=0;format_v<=0;left_v<=0;right_v<=0;line_v<=8'hFF;
    end else if(!configured_v) begin read_bank<=0;mask_v<=0;line_v<=8'hFF;end
    else if(accept_window) begin
        read_bank<=published_v;mask_v<=line_mask;left_v<=left_bounds;right_v<=right_bounds;
        line_v<=published_line;format_v<=smooth_format;
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) slide<=0;
    else if(!configured_v) slide<=0;
    else if(accept_window) begin
        if(line_v!=8'hFF && published_line==line_v+1'b1) slide<=SCROLL_DISTANCE;
        else if(published_line!=8'hFF && line_v==published_line+1'b1) slide<=-SCROLL_DISTANCE;
        else slide<=0;
    end else if(frame_start) begin
        if(slide>0) slide<=slide-SCROLL_STEP;
        else if(slide<0) slide<=slide+SCROLL_STEP;
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) pan_timer<=0;
    else if(!configured_v || accept_window) pan_timer<=0;
    else if(frame_start) pan_timer<=pan_timer+1'b1;
end
always @(posedge clk or posedge rst) begin
    if(rst) begin pan<=0;pan_reverse<=0;end
    else if(!configured_v || accept_window) begin pan<=0;pan_reverse<=0;end
    else if(frame_start && pan_timer==7 && pan_limit!=0) begin
        if(!pan_reverse && pan<pan_limit) pan<=pan+1'b1;
        else if(pan_reverse && pan!=0) pan<=pan-1'b1;
        else pan_reverse<=~pan_reverse;
    end
end
wire signed [10:0] relative_y=$signed({1'b0,y})-$signed({{3{slide[7]}},slide});
wire [5:0] small_height=format_v ? 24 : 16;
wire previous=lyrics_view && relative_y>=PREVIOUS_TOP && relative_y<PREVIOUS_TOP+small_height;
wire following=lyrics_view && relative_y>=NEXT_TOP && relative_y<NEXT_TOP+small_height;
wire [1:0] slot=!lyrics_view ? 3 : (previous ? 0 : (following ? 2 : 1));
wire current=slot==1 || slot==3;
wire [9:0] top_y=lyrics_view ? (previous ? PREVIOUS_TOP :
    (following ? NEXT_TOP : CURRENT_TOP)) : PHOTO_TOP;
wire [9:0] panel_left=lyrics_view ? LYRIC_LEFT : PHOTO_LEFT;
wire [9:0] panel_width=lyrics_view ? LYRIC_WIDTH : PHOTO_WIDTH;
wire [10:0] left_x=left_v[slot*11+:11],right_x=right_v[slot*11+:11];
wire [10:0] ink_width=right_x-left_x+1'b1;
wire has_ink=right_x>=left_x;
wire fits=ink_width<=panel_width;
wire [10:0] start_x={1'b0,panel_left}+(fits ? ((panel_width-ink_width)>>1) : 0);
wire [10:0] source_x=left_x+({1'b0,x}-start_x)+(slot==1 && !fits ? pan : 0);
wire signed [10:0] source_y=(lyrics_view ? relative_y : $signed({1'b0,y}))-top_y;
wire [5:0] row_height=format_v && slot==1 ? 32 : small_height;
wire row_valid=source_y>=0 && source_y<row_height;
wire [10:0] active_ink_width=right_v[21:11]-left_v[21:11]+1'b1;
assign pan_limit=active_ink_width>LYRIC_WIDTH && right_v[21:11]>=left_v[21:11] ?
    active_ink_width-LYRIC_WIDTH : 0;
wire valid_pixel=enabled && configured_v && ready_v && mask_v[slot] && has_ink && row_valid &&
    x>=start_x && x<panel_left+panel_width && source_x<=right_x &&
    (!lyrics_view || (y>=CLIP_TOP && y<CLIP_BOTTOM));
wire [13:0] slot_base=slot==0 ? 0 : (slot==1 ? 1536 : (slot==2 ? 5632 : 7168));
wire [13:0] row_address=slot==1 ? {2'd0,source_y[4:0],7'd0} :
    {3'd0,source_y[4:0],6'd0};
assign read_address=slot_base+row_address+{6'd0,source_x[10:3]};
reg valid_d,current_d,band_d;
reg [2:0] pixel_d;
always @(posedge clk) begin
    valid_d<=valid_pixel;current_d<=current;pixel_d<=source_x[2:0];
    band_d<=enabled && !lyrics_view && configured_v && ready_v && mask_v[3] &&
        y>=PHOTO_TOP && y<PHOTO_TOP+small_height;
end
assign text_alpha=read_data[(7-pixel_d)*2+:2];
assign band_on=band_d;
assign text_on=valid_d && text_alpha!=0;
assign text_rgb=current_d ? IVORY : MUTED;
endmodule
