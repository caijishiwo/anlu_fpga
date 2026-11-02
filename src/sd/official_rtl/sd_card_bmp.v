
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    // 扫描最多记录多少张图（改上限时同步改下面 MAX_IMAGES/CNT_BITS/IDX_BITS）
    parameter [5:0]   SCAN_TARGET_COUNT = 6'd32,
    // 连续多少个扇区没找到新图就结束扫描（512  扇区 = 256KB，约 0.25s）
    parameter [31:0]  SCAN_GAP_LIMIT    = 32'd512,
    // 加载超时（循环数 @100MHz）：源结束后等待写帧 / 连续无读图或像素输出进展
    parameter [31:0]  TIMEOUT_WRITE     = 32'd5_000_000,
    parameter [31:0]  TIMEOUT_LOAD      = 32'd200_000_000
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input [1:0]                 photo_requests,
    input                       key_auto,
    input                       manual_mode,
    input music_controlled,music_restart,
    input [31:0] music_sector,music_frames,
    output music_safe,music_finished,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,

    input                       write_finish_toggle,
    input  [1:0]                active_buf_idx,        // 视频端当前正在读的 bank（预取写入必须避开）
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,
    // 板级诊断灯：{按键闪光, 加载失败, 扫描张数闪灯, display_valid}
    //   LED2 上电后闪 N 次 = 扫描到 N 张图（闪完常亮；N=0 时一直灭）
    //   LED4 每按一次键亮 0.5s = 按键是否被识别
    output      [3:0]           dbg_status,
    // 串口日志用：{found[4:0],scan_valid,load_failed,preload_done,cur_img[3:0],key_cnt[3:0]}
    output      [17:0]          dbg_info,
    // 异常码 + 轮播状态（给屏幕 OSD 与串口日志用，不参与任何控制）
    output      [7:0]           err_code,
    output                      auto_en,
    output                      dbg_key_pulse,
    output      [31:0]          dbg_scan_sector,
    output      [15:0]          dbg_read_cnt,
    output      [7:0]           dbg_fs_kind,
    output      [3:0]           dbg_dir_flags,
    // audio streaming: FIFO level in / FIFO write out
    input       [9:0]           aud_fifo_used,
    output                      aud_wr_en,
    output      [31:0]          aud_wr_data,
    output      [31:0]          audio_frame_pos,     // 当前播放帧号（字幕对齐用）

    // 字幕数据（LYRIC.BIN）位置 + 字幕模块共用的 SD 读口（第三路仲裁）
    output                      lyric_valid,
    output [31:0]               lyric_start_sector,
    output                      ui_file_valid,
    output                      ui_scan_done,
    output [31:0]               ui_file_sector,
    output [31:0]               ui_file_bytes,
    input wire [6:0] photo_settings,
    input wire ui_sec_write,
    input wire [7:0] ui_write_data,
    output wire ui_write_next,ui_write_end,ui_write_error,
    input                       ui_sec_req,
    input  [31:0]               ui_sec_addr,
    output                      ui_sec_data_valid,
    output                      ui_sec_end,
    output [7:0]                ui_sec_data,
    input                       lyr_sec_req,
    input  [31:0]               lyr_sec_addr,
    output                      lyr_sec_data_valid,
    output                      lyr_sec_end,
    output [7:0]                lyr_sec_data,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire [4:0] nav_target;
wire nav_pending,nav_dispatch;
`include "bmp_state_signals.vh"
wire nav_auto=(!manual_sync[1] && auto_play_en && auto_tick &&
               img_found_count>1 && !load_busy);
photo_navigation u_navigation(
    .clk(clk),.rst(rst || !sd_init_done),.requests(photo_requests),
    .next_pulse(key_next_press || nav_auto),.count(img_found_count),
    .current(cur_img),.display_valid(display_valid),
    .bad_valid(bad_img_valid),.bad_image(bad_img),
    .target(nav_target),.pending(nav_pending),.dispatch(nav_dispatch));
`include "bmp_cache_logic.vh"
`include "bmp_target_pipeline.vh"

`include "bmp_image_control.vh"

bmp_image_reader bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_gap_limit         (SCAN_GAP_LIMIT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (bmp_sec_read),
    .sd_sec_read_addr       (bmp_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (bmp_sec_read_data_valid),
    .sd_sec_read_end        (bmp_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
    ,
    .dbg_scan_sector        (dbg_scan_sector),
    .dbg_read_cnt           (dbg_read_cnt),
    .dbg_fs_kind            (dbg_fs_kind),
    .dbg_dir_flags          (dbg_dir_flags),
    .lyric_valid            (lyric_valid),
    .lyric_start_sector     (lyric_start_sector),
    .ui_file_valid          (ui_file_valid),
    .ui_file_sector         (ui_file_sector),
    .ui_file_bytes          (ui_file_bytes),
    .audio_found            (audio_found),
    .audio_start_sector     (audio_start_sector),
    .audio_frames           (audio_frames)
);

`include "bmp_sd_bus.vh"

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
