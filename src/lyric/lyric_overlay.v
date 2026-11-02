`timescale 1ns/1ps
// 实际LYR索引、三行双缓冲和视频渲染分别实现，统一一拍同步像素契约。
module lyric_overlay #(parameter [31:0] CHECK_DIV=32'd1000000)(
    input wire sd_clk,rst,reload,file_valid,
    input wire [31:0] file_start_sector,play_frame,
    output wire sec_req,
    output wire [31:0] sec_addr,
    input wire sec_data_valid,sec_end,
    input wire [7:0] sec_data,
    output wire [7:0] dbg_line,
    output wire [3:0] dbg_state,
    output wire [15:0] dbg_nlines,
    input wire vid_clk,vs,enabled,lyrics_view,
    input wire [9:0] x,y,
    output wire band_on,text_on,
    output wire [23:0] text_rgb,
    output wire [1:0] text_alpha
);
wire index_req,fetch_req,configured,window_ready,published,read_bank;
wire [31:0] index_sector,fetch_sector,data_sector;
wire [7:0] nlines,current_line,published_line;
wire [3:0] index_state,fetch_state;
wire write_enable,write_bank;
wire smooth_format;
wire [13:0] write_address,read_address;
wire [15:0] write_data,read_data;
wire [3:0] line_mask;
wire [43:0] left_bounds,right_bounds;
reg [31:0] file_sector_d;
reg file_valid_d;
always @(posedge sd_clk or posedge rst) begin
    if(rst) begin file_sector_d<=0;file_valid_d<=0;end
    else begin file_sector_d<=file_start_sector;file_valid_d<=file_valid;end
end
assign sec_req=index_req || fetch_req;
assign sec_addr=configured ? fetch_sector : index_sector;
assign dbg_line=published_line;
assign dbg_state=index_state==15 || fetch_state==15 ? 15 : (fetch_state!=0 ? fetch_state+6 : index_state);
assign dbg_nlines={8'd0,nlines};
lyric_index #(.CHECK_DIV(CHECK_DIV)) u_index(
    .clk(sd_clk),.rst(rst),.reload(reload),.file_valid(file_valid_d),
    .file_start_sector(file_sector_d),.play_frame(play_frame),
    .sec_data_valid(sec_data_valid),.sec_end(sec_end),.sec_data(sec_data),
    .sec_req(index_req),.sec_addr(index_sector),.configured(configured),.smooth_format(smooth_format),
    .nlines(nlines),.current_line(current_line),.data_sector(data_sector),.state(index_state));
lyric_window_loader u_loader(
    .clk(sd_clk),.rst(rst),.reload(reload),.configured(configured),.smooth_format(smooth_format),
    .nlines(nlines),.current_line(current_line),.data_sector(data_sector),
    .sec_data_valid(sec_data_valid),.sec_end(sec_end),.sec_data(sec_data),
    .front_ack(read_bank),.sec_req(fetch_req),.sec_addr(fetch_sector),
    .write_enable(write_enable),.write_bank(write_bank),.write_address(write_address),
    .write_data(write_data),.published(published),.window_ready(window_ready),
    .line_mask(line_mask),.left_bounds(left_bounds),.right_bounds(right_bounds),
    .published_line(published_line),.state(fetch_state));
lyric_window_cache u_cache(
    .write_clk(sd_clk),.read_clk(vid_clk),.write_enable(write_enable),
    .write_bank(write_bank),.read_bank(read_bank),.write_address(write_address),
    .read_address(read_address),.write_data(write_data),.read_data(read_data));
lyric_window_renderer u_renderer(
    .clk(vid_clk),.rst(rst),.vs(vs),.enabled(enabled),.lyrics_view(lyrics_view),
    .configured(configured),.window_ready(window_ready),.published(published),.smooth_format(smooth_format),
    .line_mask(line_mask),.left_bounds(left_bounds),.right_bounds(right_bounds),
    .published_line(published_line),.x(x),.y(y),.read_data(read_data),
    .read_bank(read_bank),.read_address(read_address),
    .band_on(band_on),.text_on(text_on),.text_rgb(text_rgb),.text_alpha(text_alpha));
endmodule
