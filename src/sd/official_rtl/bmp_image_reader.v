// 扫描沿用现有文件系统解析器；显示加载固定使用按需读取，无运行时回退分支。
module bmp_image_reader(
 input wire clk,rst,scan_start,load_start,load_abort,sd_init_done,
 input wire [31:0] scan_start_sector,scan_max_sector,scan_gap_limit,load_sector,
 input wire [5:0] scan_target_count,
 input wire [15:0] bmp_width,bmp_height,
 output wire ready,scan_done,scan_found_valid,
 output wire [31:0] scan_found_sector,
 output wire [5:0] scan_found_total,
 output wire [3:0] state_code,
 output wire write_req,
 input wire write_req_ack,
 output wire sd_sec_read,
 output wire [31:0] sd_sec_read_addr,
 input wire [7:0] sd_sec_read_data,
 input wire sd_sec_read_data_valid,sd_sec_read_end,
 output wire bmp_data_wr_en,
 output wire [23:0] bmp_data,
 output wire [31:0] dbg_scan_sector,
 output wire [15:0] dbg_read_cnt,
 output wire [7:0] dbg_fs_kind,
 output wire [3:0] dbg_dir_flags,
 output wire lyric_valid,ui_file_valid,audio_found,
 output wire [31:0] lyric_start_sector,ui_file_sector,ui_file_bytes,
 output wire [31:0] audio_start_sector,audio_frames
);
wire scan_ready,scan_request,load_ready,load_request,load_failed;
wire [31:0] scan_address,load_address;
wire [15:0] scan_reads,load_reads;
wire [3:0] scan_state;
wire loading=!load_ready || load_start;
assign ready=scan_ready && load_ready;
assign sd_sec_read=loading ? load_request : scan_request;
assign sd_sec_read_addr=loading ? load_address : scan_address;
assign state_code=loading ? (load_failed ? 4'd15 : (write_req ? 4'd3 : 4'd4)) : scan_state;
assign dbg_read_cnt=scan_reads+load_reads;
// 流式读取器仍作为逐像素和性能基准；生产连接只启用其中的目录扫描。
bmp_read scanner(.clk(clk),.rst(rst),.ready(scan_ready),
 .scan_start(scan_start),.scan_start_sector(scan_start_sector),
 .scan_max_sector(scan_max_sector),.scan_target_count(scan_target_count),
 .scan_gap_limit(scan_gap_limit),.scan_done(scan_done),.scan_found_valid(scan_found_valid),
 .scan_found_sector(scan_found_sector),.scan_found_total(scan_found_total),
 .load_start(1'b0),.load_abort(1'b0),.load_sector(32'd0),.sd_init_done(sd_init_done),
 .state_code(scan_state),.bmp_width(bmp_width),.bmp_height(bmp_height),
 .write_req(),.write_req_ack(1'b0),.sd_sec_read(scan_request),.sd_sec_read_addr(scan_address),
 .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid && !loading),
 .sd_sec_read_end(sd_sec_read_end && !loading),.bmp_data_wr_en(),.bmp_data(),
 .dbg_scan_sector(dbg_scan_sector),.dbg_read_cnt(scan_reads),.dbg_fs_kind(dbg_fs_kind),
 .dbg_dir_flags(dbg_dir_flags),.lyric_valid(lyric_valid),.lyric_start_sector(lyric_start_sector),
 .ui_file_valid(ui_file_valid),.ui_file_sector(ui_file_sector),.ui_file_bytes(ui_file_bytes),
 .audio_found(audio_found),.audio_start_sector(audio_start_sector),.audio_frames(audio_frames));
bmp_fast_load loader(.clk(clk),.rst(rst || !sd_init_done),.start(load_start),
 .abort(load_abort),.first_sector(load_sector),.ready(load_ready),
 .write_req(write_req),.write_req_ack(write_req_ack),.sd_req(load_request),
 .sd_address(load_address),.sd_data(sd_sec_read_data),
 .sd_valid(sd_sec_read_data_valid && loading),.sd_end(sd_sec_read_end && loading),
 .out_valid(bmp_data_wr_en),.out_pixel(bmp_data),.failed(load_failed),.read_count(load_reads));
endmodule
