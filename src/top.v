`timescale 1ns / 1ps

module top #(parameter MENU_UART_DEBUG=1'b1) (
    input wire clk, rst_n, key1, key2, key_flip,
    output wire HDMI_CLK_P, HDMI_D2_P, HDMI_D1_P, HDMI_D0_P,
    output wire HDMI_DDC_SCL,
    inout wire HDMI_DDC_SDA,
    output wire sd_ncs, sd_dclk, sd_mosi,
    input wire sd_miso,
    // 串口日志（115200 8N1）：rxd = F12，txd = D12
    input wire uart_rxd,
    output wire uart_txd,
    // 板载 4 个 LED，用于显示 sd_card_bmp 的调试状态（1 = 点亮）
    output wire [3:0] led
    ,
    // 板载 6 位数码管（共阳、低电平点亮）
    output wire [5:0] seg_sel,
    output wire [7:0] seg_data
);

localparam integer FRAME_WIDTH = 640, FRAME_HEIGHT = 480;
localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
localparam integer ADDR_BITS = 21, MEM_DATA_BITS = 32;
localparam integer EDID_TRIG_CYCLES = 100000;
localparam [10:0] H_ACTIVE_LAST = 11'd639;
localparam [ADDR_BITS-1:0] BANK0_ADDR = 21'd0;
localparam [ADDR_BITS-1:0] BANK1_ADDR = 21'd307200;
localparam [ADDR_BITS-1:0] BANK2_ADDR = 21'd614400;
localparam [ADDR_BITS-1:0] BANK3_ADDR = 21'd921600;

wire sd_clk, mem_clk, mem_clk_sft, video_clk, hdmi_5x_clk;
wire sys_pll_lock, video_pll_lock, rst_all;
reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg;
reg rst_released = 1'b0;         // 复位释放后锁定，避免 PLL lock 抖动重启整机

wire sdr_init_done, sdr_init_ref_vld, sdr_busy;
wire app_rd_en, sdr_rd_en, app_wr_en;
wire [ADDR_BITS-1:0] app_rd_addr, app_wr_addr;
wire [MEM_DATA_BITS-1:0] sdr_rd_dout, app_wr_din;
wire [3:0] app_wr_dm;
wire video_app_rd_en, video_app_wr_en, video_sdr_rd_en;
wire [ADDR_BITS-1:0] video_app_rd_addr, video_app_wr_addr;
wire [MEM_DATA_BITS-1:0] video_app_wr_din;
wire [3:0] video_app_wr_dm;
wire cpu_app_req, cpu_app_is_write, cpu_app_grant;
wire cpu_sdram_busy, video_sdram_busy;
wire cpu_app_rd_en, cpu_app_wr_en, cpu_sdr_rd_en;
wire [ADDR_BITS-1:0] cpu_app_rd_addr, cpu_app_wr_addr;
wire [MEM_DATA_BITS-1:0] cpu_app_wr_din;
wire [3:0] cpu_app_wr_dm;

wire sd_card_write_req, sd_card_write_req_ack, sd_card_write_en;
wire [31:0] sd_card_write_data;
wire [1:0]  write_buf_idx, disp_buf_idx;
wire        display_valid;
wire [3:0]  led_status;          // {preload_done, 有过加载失败, scan_done, display_valid}
wire [17:0] dbg_info;            // 串口日志用
wire        dbg_key_pulse;
wire [3:0]  dbg_state;
wire [31:0] dbg_scan_sector;
wire [15:0] dbg_read_cnt;
wire [7:0]  dbg_fs_kind;         // 串口日志：文件系统/簇大小
wire [3:0]  dbg_dir_flags;       // 串口日志：目录法诊断 {目录生效,MUSIC,PICTURE,音频}
// ---- 歌词字幕：TF 卡 LYRIC.BIN → 叠加到画面上 ----
wire        lyric_valid, lyr_sec_req, lyr_sec_data_valid, lyr_sec_end;
wire [31:0] lyric_start_sector, lyr_sec_addr;
wire ui_file_valid;
wire ui_scan_done;
wire [31:0] ui_file_sector, ui_file_bytes;
wire ui_sec_req, ui_sec_data_valid, ui_sec_end;
wire ui_sec_write,ui_write_next,ui_write_end,ui_write_error;
wire [7:0] ui_write_data;
wire [6:0] photo_settings;
wire [31:0] ui_sec_addr;
wire [7:0] ui_sec_data;
wire [31:0] audio_frame_pos;     // 当前播放帧号（48000 帧/秒）
wire music_safe,music_finished,music_controlled,music_restart;
wire [31:0] music_sector,music_frames,music_lyric;
wire        lyric_band, lyric_text;
wire [7:0]  lyric_dbg_line;
wire [3:0]  lyric_dbg_state;
wire [15:0] lyric_dbg_nlines;
wire [7:0]  lyr_sec_data;
// ---- 数码管菜单 ----
wire        menu_active, menu_subtitle, menu_fx;
wire [7:0]  menu_bright, menu_contrast;   // 亮度 0~255(255=原图) / 对比度 0~255(128=原图)
wire        menu_osd;                     // 状态 OSD 开关
assign menu_active = 1'b0;
assign menu_subtitle = 1'b1;
assign menu_fx = 1'b1;
assign menu_bright = 8'hff;
assign menu_contrast = 8'h80;
assign menu_osd = 1'b0;
// ---- RISC-V + LVGL 彩色 HDMI 菜单页 ----
wire        cpu_ui_enable, cpu_menu_active, cpu_menu_visible;
wire        cpu_auto_trigger;
wire [1:0] cpu_photo_requests;
wire [2:0]  cpu_menu_item;
wire        cpu_flip, cpu_subtitle, cpu_fx, cpu_osd;
wire [7:0]  cpu_bright, cpu_contrast;
wire        cpu_menu_page, cpu_menu_pixel, cpu_run_led;
wire cpu_overlay_mode, cpu_player_mode, cpu_menu_accent, cpu_menu_muted, cpu_lyrics_view;
wire        ui_menu_active = cpu_ui_enable ? cpu_menu_active : menu_active;
wire        ui_subtitle    = cpu_ui_enable ? cpu_subtitle    : menu_subtitle;
wire        ui_fx          = cpu_ui_enable ? cpu_fx          : menu_fx;
wire        ui_osd         = cpu_ui_enable ? cpu_osd         : menu_osd;
wire [7:0]  ui_bright      = cpu_ui_enable ? cpu_bright      : menu_bright;
wire [7:0]  ui_contrast    = cpu_ui_enable ? cpu_contrast    : menu_contrast;
wire [7:0]  sd_err_code;                  // sd_card_bmp 上报的异常码
wire        sd_auto_en;                   // 自动轮播中
// 音频可视化：双声道电平律动柱（模块见 src/audio/audio_scope.v）
wire [95:0] ui_audio_levels;
wire        uart_rst_n;
wire        menu_uart_tx, media_uart_tx;
assign uart_txd = MENU_UART_DEBUG ? menu_uart_tx : media_uart_tx;
// ---- audio path (HDMI embedded audio) ----
wire        audio_pll_lock, audio_mclk, audio_i2s_bclk, audio_i2s_lrck, audio_i2s_dout;
wire        audio_valid;
wire [23:0] audio_left_data, audio_right_data;
wire [23:0] audio_left_eq, audio_right_eq;
wire [23:0] audio_left_ready, audio_right_ready;
wire audio_valid_eq;
wire [10:0] cpu_audio_settings;
wire        acr_valid;
wire [19:0] acr_cts, acr_n;

// ---- TF card audio streaming: SD -> FIFO -> I2S ----
wire        aud_wr_en;
wire [31:0] aud_wr_data;
wire [8:0]  aud_wrusedw;
wire        aud_fifo_empty;
wire [31:0] aud_fifo_dout;
wire        aud_fifo_re;
wire        aud_afull;
wire        tone_bclk, tone_lrck, tone_dout;
wire        pl_bclk, pl_lrck, pl_dout;
wire        i2s_bclk_sel, i2s_lrck_sel, i2s_dout_sel;
reg         aud_seen;

wire video_read_req_raw, video_read_req, video_read_req_ack;
wire video_read_req_ack_gated, video_read_en, frame_write_finish;
wire [31:0] video_read_data;
wire hs_0, vs_0, de_0, hs, vs, de;
wire [23:0] vout_data;

reg frame_done_toggle_mem, vs_0_d1;
reg [1:0] read_buf_idx_active;
reg [20:0] hs_shift, vs_shift, de_shift;
reg [23:0] vout_data_r;

// ---- 切图特效：亮度来自独立模块 fx_alpha（每次换图自动轮换 4 种）----
wire [7:0]  fx_alpha_val;
// 8x8 乘法必须显式 16 位，否则 Verilog 按上下文宽度截成 8 位 → 结果为 0（全黑）
// 菜单里关掉特效时固定满亮度（不改 fx_alpha 内部逻辑）
wire [7:0]  fx_val      = ui_fx ? fx_alpha_val : 8'hFF;
// 亮度折进这条已有的 alpha 通路：gain = fx_val * (bright+1) / 256。
// bright=255 时恰好 1.0（原图不变）；menu_fx 关掉特效时 fx_val=0xFF，亮度仍然有效。
// 位宽必须写够 17 位，否则按上下文截断（与下面 fade_mul 同理），结果会全黑。
wire [16:0] fx_gain     = fx_val * (ui_bright + 8'd1);
wire [7:0]  fx_val_eff  = fx_gain[15:8];
wire [15:0] fade_mul_r = video_read_data[31:24] * fx_val_eff;
wire [15:0] fade_mul_g = video_read_data[23:16] * fx_val_eff;
wire [15:0] fade_mul_b = video_read_data[15:8]  * fx_val_eff;

reg vs_d1, de_d1, frame_arm, axis_s_user, axis_s_valid, axis_s_last;
reg [10:0] x_cnt;
reg [19:0] edid_cnt;
reg edid_done, edid_trig;
reg [23:0] axis_s_data;
wire axis_s_ready, edid_valid;
wire [7:0] edid_data;
wire [9:0] tmds_ch0_data, tmds_ch1_data, tmds_ch2_data, tmds_clk_data;

assign rst_all = rst_all_reg;
assign led = {cpu_ui_enable ? cpu_run_led : led_status[3], led_status[2:0]};
assign uart_rst_n = ~rst_all;
assign video_read_req = display_valid & video_read_req_raw;
assign video_read_req_ack_gated =
    display_valid ? video_read_req_ack : 1'b0;
assign video_read_en = display_valid & de_shift[18];
assign hs = hs_shift[20];
assign vs = vs_shift[20];
assign de = de_shift[20];
// 歌词叠加：字幕条内文字画白，底条把底图压暗一半。
// 注意每个通道都要补回 1 位（8 位 = 1 位 0 + 右移 1 位的 7 位），
// 否则三通道拼出来只有 21 位，零扩展后颜色会整体错位。
// ---- 实时对比度调节（亮度已在上面折进 alpha 通路）----
// y = (x-128)*c/128 + 128  ==>  (x*c + 16384 - 128*c) / 128
// 这样展开后全程非负分支，只需最后做一次 0..255 饱和截断。
// 位宽刻意压到 8x8 乘法（16 位积）：写成 32 位会被生成大乘法器，
// 在 80% slices 的占用下会直接撞布线（PHY-8023），与工程里其它乘法器保持一致。
function [7:0] sat8;
    input signed [19:0] v;
    begin
        if (v < 20'sd0)        sat8 = 8'd0;
        else if (v > 20'sd255) sat8 = 8'd255;
        else                   sat8 = v[7:0];
    end
endfunction

wire [7:0]  ctr_k    = ui_contrast;
wire [15:0] ctr_pr_r = vout_data_r[23:16] * ctr_k;
wire [15:0] ctr_pr_g = vout_data_r[15:8]  * ctr_k;
wire [15:0] ctr_pr_b = vout_data_r[7:0]   * ctr_k;
// 偏置 = 16384 - 128*c，范围 -16256..16384，20 位有符号足够
wire signed [19:0] ctr_bias = 20'sd16384 - ($signed({1'b0, ctr_k}) <<< 7);
wire signed [19:0] ctr_num_r = $signed({4'b0, ctr_pr_r}) + ctr_bias;
wire signed [19:0] ctr_num_g = $signed({4'b0, ctr_pr_g}) + ctr_bias;
wire signed [19:0] ctr_num_b = $signed({4'b0, ctr_pr_b}) + ctr_bias;
wire [23:0] vout_adj = {sat8(ctr_num_r >>> 7), sat8(ctr_num_g >>> 7), sat8(ctr_num_b >>> 7)};

// ==================== 状态 OSD（左上角） ====================
// 6 个字符：<图号十位><图号个位>/<总数十位><总数个位><状态字>
// 5x7 点阵、4 倍放大：字符格 20x28，横向步距 32、纵向步距 28
// 坐标计数与 vout_data_r 对齐：两者都来自同一条 de 移位链，OSD 坐标再迟一拍。

reg [9:0] osd_x, osd_y, osd_px, osd_py;
reg osd_de_prev, osd_vs_prev, osd_first_line;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        osd_x <= 10'd0; osd_y <= 10'd0;
        osd_px <= 10'd0; osd_py <= 10'd0;
        osd_de_prev <= 1'b0; osd_vs_prev <= 1'b0;
        osd_first_line <= 1'b1;
    end else begin
        osd_de_prev <= de_shift[19];
        osd_vs_prev <= vs_shift[19];
        if (vs_shift[19] != osd_vs_prev) begin
            osd_x <= 10'd0; osd_y <= 10'd0;
            osd_first_line <= 1'b1;
        end else if (de_shift[19]) begin
            if (!osd_de_prev) begin
                osd_x <= 10'd1;
                osd_px <= 10'd0;
                osd_py <= osd_first_line ? 10'd0 : osd_y + 10'd1;
                osd_y <= osd_first_line ? 10'd0 : osd_y + 10'd1;
                osd_first_line <= 1'b0;
            end else begin
                osd_px <= osd_x; osd_py <= osd_y;
                osd_x <= osd_x + 10'd1;
            end
        end
    end
end

wire [23:0] normal_mix = vout_adj;
wire [23:0] vout_mix = normal_mix;
wire record_hit;
wire [23:0] record_rgb;
wire [2:0] record_alpha;
record_overlay u_record_overlay (
    .clk(video_clk), .rst(rst_all), .vs(vs),
    .enabled(cpu_overlay_mode), .disc_enabled(cpu_lyrics_view),
    .x(osd_px), .y(osd_py), .levels(ui_audio_levels),
    .hit(record_hit), .rgb(record_rgb), .alpha(record_alpha)
);
// 照片、官方RAM圆环、歌词RAM及OSD均在同一拍输出，避免字形拖影。
wire [23:0] lyric_rgb;
wire [1:0] lyric_alpha;
reg [23:0] player_base_d;
// 歌词页保留当前照片的25%亮度；图片页仍使用原图亮度。
wire [23:0] player_photo = cpu_lyrics_view ?
    {2'b00,player_base_d[23:18],2'b00,player_base_d[15:10],2'b00,player_base_d[7:2]} :
    player_base_d;
// 歌词与圆环共用同一灰度混合器，避免复制逐通道加法器。
wire [2:0] lyric_coverage=lyric_alpha==2'b11 ? 3'd7 : {lyric_alpha,1'b0};
wire [23:0] player_mix;
overlay_blend u_overlay_blend (
    .background(player_photo), .foreground(lyric_text ? lyric_rgb : record_rgb),
    .coverage(lyric_text ? lyric_coverage : (record_hit ? record_alpha : 3'd0)),
    .rgb(player_mix)
);
reg player_de, player_vs;
always @(posedge video_clk or posedge rst_all) begin
    if(rst_all) begin player_base_d<=0; player_de<=0; player_vs<=0; end
    else begin
        player_base_d<=vout_data;
        player_de<=de; player_vs<=vs;
    end
end
wire [23:0] player_output = cpu_menu_page ?
    (cpu_menu_pixel ? (cpu_menu_muted ? 24'h777A74 : 24'hE8E6DE) :
    (cpu_menu_muted ? 24'h41443F :
    ({2'b00,player_mix[23:18],2'b00,player_mix[15:10],2'b00,player_mix[7:2]}+
     {3'b000,player_mix[23:19],3'b000,player_mix[15:11],3'b000,player_mix[7:3]}+
     (cpu_menu_accent ? 24'h161616 : 24'h000000)))) : player_mix;
assign vout_data = display_valid ? vout_mix : 24'd0;

// 切图特效：输出本像素亮度（0=黑）。每次换图自动轮换：淡入 / 下擦 / 中心展开 / 百叶窗
fx_alpha u_fx_alpha (
    .clk    (video_clk),
    .rst    (rst_all),
    .de     (de),
    .vs     (vs),
    .valid  (display_valid),
    .img_id ({dbg_info[7:4], disp_buf_idx}),
    .alpha  (fx_alpha_val)
);



always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rst_cnt      <= 20'd0;
        rst_all_reg  <= 1'b1;
        rst_released <= 1'b0;
    end else if (!rst_released) begin
        // 两个 PLL 锁定后连续计时 20ms 再释放复位
        if (sys_pll_lock && video_pll_lock) begin
            if (rst_cnt < 20'd1000000) begin
                rst_cnt     <= rst_cnt + 1'b1;
                rst_all_reg <= 1'b1;
            end else begin
                rst_all_reg  <= 1'b0;
                rst_released <= 1'b1;
            end
        end else begin
            rst_cnt     <= 20'd0;
            rst_all_reg <= 1'b1;
        end
    end
end

sys_pll u_sys_pll (
    .refclk(clk), .reset(1'b0), .extlock(sys_pll_lock),
    .clk0_out(sd_clk), .clk1_out(mem_clk), .clk2_out(mem_clk_sft)
);

video_pll u_video_pll (
    .refclk(clk), .reset(1'b0), .extlock(video_pll_lock),
    .clk0_out(video_clk), .clk1_out(hdmi_5x_clk)
);

riscv_menu_system u_riscv_menu_system (
    .cpu_clk(video_clk), .rst(rst_all),
    .key_next(key1), .key_dec(key_flip), .key_menu(key2),
    .img_found(dbg_info[17:12]), .img_cur(dbg_info[8:4]),
    .audio_frame(audio_frame_pos), .audio_levels(ui_audio_levels),
    .music_safe(music_safe),.music_finished(music_finished),
    .music_controlled(music_controlled),.music_restart(music_restart),
    .music_sector(music_sector),.music_frames(music_frames),.music_lyric(music_lyric),
    .lyric_line(lyric_dbg_line),
    .sd_err_code(sd_err_code), .sd_auto_en(sd_auto_en),
    .ui_file_valid(ui_file_valid), .ui_scan_done(ui_scan_done),
    .ui_file_sector(ui_file_sector),
    .ui_file_bytes(ui_file_bytes),
    .sd_clk(sd_clk), .ui_sec_req(ui_sec_req),
    .ui_sec_addr(ui_sec_addr), .ui_sec_data_valid(ui_sec_data_valid),
    .photo_settings(photo_settings),
    .ui_sec_write(ui_sec_write),.ui_write_data(ui_write_data),
    .ui_write_next(ui_write_next),.ui_write_end(ui_write_end),
    .ui_write_error(ui_write_error),
    .ui_sec_data(ui_sec_data), .ui_sec_end(ui_sec_end),
    .vid_clk(video_clk), .vid_de(de_shift[19]), .vid_vs(vs),
    .vid_x(osd_px), .vid_y(osd_py), .run_led(cpu_run_led), .debug_tx(menu_uart_tx),
    .mem_clk(mem_clk), .sdr_init_done(sdr_init_done),
    .sdr_rd_en(cpu_sdr_rd_en), .sdr_rd_dout(sdr_rd_dout),
    .cpu_app_req(cpu_app_req), .cpu_app_is_write(cpu_app_is_write),
    .cpu_app_grant(cpu_app_grant),
    .app_wr_en(cpu_app_wr_en), .app_wr_addr(cpu_app_wr_addr),
    .app_wr_dm(cpu_app_wr_dm), .app_wr_din(cpu_app_wr_din),
    .app_rd_en(cpu_app_rd_en), .app_rd_addr(cpu_app_rd_addr),
    .cpu_enable(cpu_ui_enable), .menu_active(cpu_menu_active),
    .menu_visible(cpu_menu_visible),
    .color_frame_ready(),
    .color_frame_bank(),
    .auto_trigger(cpu_auto_trigger), .menu_item(cpu_menu_item),
    .photo_requests(cpu_photo_requests),
    .set_flip(cpu_flip), .en_subtitle(cpu_subtitle),
    .en_fx(cpu_fx), .en_osd(cpu_osd), .bright_level(cpu_bright),
    .contrast_level(cpu_contrast), .diag_word(),
    .audio_settings(cpu_audio_settings),
    .menu_page(cpu_menu_page),
    .menu_pixel(cpu_menu_pixel), .menu_accent(cpu_menu_accent),
    .overlay_mode(cpu_overlay_mode), .player_mode(cpu_player_mode),
    .lyrics_view(cpu_lyrics_view), .menu_muted(cpu_menu_muted)
);

// ---- audio master clock (PLL_HDMI_AUDIO, C2 out ~12.295MHz) ----
PLL_HDMI_AUDIO u_audio_pll (
    .refclk(clk), .reset(1'b0), .extlock(audio_pll_lock),
    .clk0_out(), .clk1_out(), .clk2_out(audio_mclk)
);

// ---- KEY3(B1)：显示上下翻转开关（图片方向不对时按一下即整屏翻转）----
wire key_flip_press;
reg  flip_mode;
key_press_debounce #(
    .CLK_FREQ_HZ (50_000_000),
    .DEBOUNCE_MS (50)
) u_key_flip (
    .clk        (clk),
    .rst        (rst_all),
    .button_in  (key_flip),
    .press_pulse(key_flip_press)
);
always @(posedge clk or posedge rst_all) begin
    if (rst_all)                              flip_mode <= 1'b0;
    else if (cpu_ui_enable)                   flip_mode <= cpu_flip;
    else if (key_flip_press)                  flip_mode <= ~flip_mode;
end

sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    // 扫描上限（扇区）：只作为安全边界，实际由“连续 64 扇区没新图”停。
    // 大容量卡的数据区可能靠后，所以放宽到 4M 扇区（2GB）。
    .SCAN_MAX_SECTOR   (32'd4194303),
    .SCAN_TARGET_COUNT (6'd32),         // 最多记录 32 张图（多于 4 张时按需从 SD 读）
    // 连续多少个扇区没新图就结束扫描：64 扇区 = 32KB。
    // 图片是连续存放的（间隔通常只有几个扇区），所以 64 足够；
    // 设太大（例如 4096）会让扫描逐扇区读上千次，真实卡上要好几秒甚至更久，
    // 期间屏幕全黑、LED 全灭，看起来像"死机"。
    .SCAN_GAP_LIMIT    (32'd64)
) u_sd_card_bmp (
    .clk(sd_clk), .rst(rst_all),
    .key_next(cpu_ui_enable ? 1'b1 : key1),
    .photo_requests(cpu_photo_requests),
    .manual_mode(1'b0),
    .music_controlled(music_controlled),.music_restart(music_restart),
    .music_sector(music_sector),.music_frames(music_frames),
    .music_safe(music_safe),.music_finished(music_finished),
    // KEY4 只交给菜单；轮播仅响应菜单中的自动轮播命令。
    .key_auto(~cpu_auto_trigger),
    .bmp_width(16'd640), .bmp_height(16'd480),
    .display_valid(display_valid),
    .dbg_status(led_status),
    .dbg_info(dbg_info),
    .dbg_key_pulse(dbg_key_pulse),
    .dbg_scan_sector(dbg_scan_sector),
    .err_code(sd_err_code),
    .auto_en(sd_auto_en),
    .dbg_read_cnt(dbg_read_cnt),
    .dbg_fs_kind(dbg_fs_kind),
    .dbg_dir_flags(dbg_dir_flags),
    .aud_fifo_used({1'b0, aud_wrusedw}),
    .aud_wr_en(aud_wr_en),
    .aud_wr_data(aud_wr_data),
    .audio_frame_pos(audio_frame_pos),
    .lyric_valid(lyric_valid),
    .lyric_start_sector(lyric_start_sector),
    .ui_file_valid(ui_file_valid),
    .ui_scan_done(ui_scan_done),
    .ui_file_sector(ui_file_sector),
    .ui_file_bytes(ui_file_bytes),
    .photo_settings(photo_settings),
    .ui_sec_req(ui_sec_req), .ui_sec_addr(ui_sec_addr),
    .ui_sec_write(ui_sec_write),.ui_write_data(ui_write_data),
    .ui_write_next(ui_write_next),.ui_write_end(ui_write_end),
    .ui_write_error(ui_write_error),
    .ui_sec_data_valid(ui_sec_data_valid),
    .ui_sec_end(ui_sec_end), .ui_sec_data(ui_sec_data),
    .lyr_sec_req(lyr_sec_req),
    .lyr_sec_addr(lyr_sec_addr),
    .lyr_sec_data_valid(lyr_sec_data_valid),
    .lyr_sec_end(lyr_sec_end),
    .lyr_sec_data(lyr_sec_data),
    .state_code(dbg_state),
    .write_finish_toggle(frame_done_toggle_mem),
    .active_buf_idx(read_buf_idx_active),
    .write_buf_idx(write_buf_idx), .disp_buf_idx(disp_buf_idx),
    .write_req(sd_card_write_req), .write_req_ack(sd_card_write_req_ack),
    .write_en(sd_card_write_en), .write_data(sd_card_write_data),
    .SD_nCS(sd_ncs), .SD_DCLK(sd_dclk), .SD_MOSI(sd_mosi), .SD_MISO(sd_miso)
);

// ---- 按实际播放帧号取原生双字号灰度字形；旧卡单色格式显式兼容 ----
lyric_overlay u_lyric_overlay (
    .sd_clk            (sd_clk),
    .rst               (rst_all),
    .file_valid        (music_controlled && music_lyric!=0),
    .file_start_sector (music_lyric),
    .reload(music_restart),
    .play_frame        (audio_frame_pos),
    .sec_req           (lyr_sec_req),
    .sec_addr          (lyr_sec_addr),
    .sec_data_valid    (lyr_sec_data_valid),
    .sec_data          (lyr_sec_data),
    .sec_end           (lyr_sec_end),
    .dbg_line          (lyric_dbg_line),
    .dbg_state         (lyric_dbg_state),
    .dbg_nlines        (lyric_dbg_nlines),
    .vid_clk           (video_clk),
    .vs                (vs),
    .enabled           (ui_subtitle),
    .lyrics_view       (cpu_lyrics_view),
    .x                 (osd_px), .y(osd_py),
    .band_on           (lyric_band),
    .text_on           (lyric_text), .text_rgb(lyric_rgb), .text_alpha(lyric_alpha)
);

// ---- 音频可视化：底部双声道电平律动柱（见 src/audio/audio_scope.v）----
audio_scope u_audio_scope (
    .clk       (video_clk),          // 全模块都在视频时钟域，无跨时钟域逻辑
    .rst       (rst_all),
    .en        (aud_seen && music_controlled),
    .samp_valid(audio_valid_eq),
    .samp_l    (audio_left_ready),
    .samp_r    (audio_right_ready),
    .vs       (vs),
    .de       (de),
    .scope_on (),
    .scope_rgb(),
    .ui_levels(ui_audio_levels)
);

// 串口日志：每 0.5 秒打一行，按键时立刻补一行（115200 8N1）
// HDMI 菜单接替数码管菜单，物理数码管保持熄灭。
assign seg_sel = 6'h3f;
assign seg_data = 8'hff;

uart_log u_uart_log (
    .clk       (clk),
    .rst_n     (uart_rst_n),
    .state_code(dbg_state),
    .info      (dbg_info),
    .key_pulse (dbg_key_pulse),
    .scan_sector(dbg_scan_sector),
    .read_cnt  (dbg_read_cnt),
    .fs_kind   (dbg_fs_kind),
    .dir_flags (dbg_dir_flags),
    .lyric_line(lyric_dbg_line),
    .audio_frame(audio_frame_pos),
    .lyric_valid(lyric_valid),
    .lyric_state(lyric_dbg_state),
    .rxd       (uart_rxd),
    .txd       (media_uart_tx)
);

always @(posedge mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_done_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_done_toggle_mem <= ~frame_done_toggle_mem;
end

video_timing_data u_video_timing_data (
    .video_clk(video_clk), .rst(rst_all), .read_req(video_read_req_raw),
    .read_req_ack(video_read_req_ack_gated), .hs(hs_0), .vs(vs_0), .de(de_0)
);

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        hs_shift <= 21'd0;
        vs_shift <= 21'd0;
        de_shift <= 21'd0;
        vout_data_r <= 24'd0;
    end else begin
        hs_shift <= {hs_shift[19:0], hs_0};
        vs_shift <= {vs_shift[19:0], vs_0};
        de_shift <= {de_shift[19:0], de_0};
        if (display_valid && de_shift[19]) begin
            // 特效：RGB 各通道乘 fx_alpha_val/256（未露出=黑）
            vout_data_r[23:16] <= fade_mul_r[15:8];
            vout_data_r[15:8]  <= fade_mul_g[15:8];
            vout_data_r[7:0]   <= fade_mul_b[15:8];
        end else begin
            vout_data_r <= 24'd0;
        end
    end
end

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        read_buf_idx_active <= 2'd0;
        vs_0_d1             <= 1'b0;
    end else begin
        vs_0_d1 <= vs_0;
        // 场同步边沿锁存 bank 号：一帧之内保持不变，避免行中途换 bank 造成画面撕裂
        if (vs_0_d1 != vs_0) begin
            read_buf_idx_active <= disp_buf_idx;
        end
    end
end

frame_read_write #(.WRITE_V_FLIP(1), .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT))
u_frame_read_write (
    .cpu_busy(cpu_sdram_busy), .video_busy(video_sdram_busy),
    .rst(rst_all), .mem_clk(mem_clk), .Sdr_init_done(sdr_init_done),
    .Sdr_init_ref_vld(sdr_init_ref_vld), .Sdr_busy(sdr_busy),
    .App_rd_en(video_app_rd_en), .App_rd_addr(video_app_rd_addr),
    .Sdr_rd_en(video_sdr_rd_en), .Sdr_rd_dout(sdr_rd_dout),
    .read_clk(video_clk), .read_req(video_read_req), .read_req_ack(video_read_req_ack),
    .read_finish(),
    .read_addr_0(BANK0_ADDR),
    .read_addr_1(BANK1_ADDR),
    .read_addr_2(BANK2_ADDR),
    .read_addr_3(BANK3_ADDR),
    .read_addr_index(read_buf_idx_active), .read_len(FRAME_PIXELS[ADDR_BITS-1:0]),
    .read_en(video_read_en), .read_data(video_read_data),
    .App_wr_en(video_app_wr_en), .App_wr_addr(video_app_wr_addr),
    .App_wr_din(video_app_wr_din), .App_wr_dm(video_app_wr_dm),
    .write_clk(sd_clk), .write_req(sd_card_write_req), .write_req_ack(sd_card_write_req_ack),
    .write_finish(frame_write_finish), .write_addr_0(BANK0_ADDR),
    .write_addr_1(BANK1_ADDR), .write_addr_2(BANK2_ADDR), .write_addr_3(BANK3_ADDR),
    .write_addr_index(write_buf_idx), .write_len(FRAME_PIXELS[ADDR_BITS-1:0]),
    .write_en(sd_card_write_en), .write_data(sd_card_write_data),
    .rd_v_flip(flip_mode)
);

sdram_ui_arbiter u_sdram_ui_arbiter (
    .cpu_busy(cpu_sdram_busy),
    .video_busy(video_sdram_busy || sdr_init_ref_vld || !sdr_init_done),
    .clk(mem_clk), .rst(rst_all),
    .video_wr_en(video_app_wr_en), .video_wr_addr(video_app_wr_addr),
    .video_wr_dm(video_app_wr_dm), .video_wr_din(video_app_wr_din),
    .video_rd_en(video_app_rd_en), .video_rd_addr(video_app_rd_addr),
    .video_rd_valid(video_sdr_rd_en),
    .cpu_req(cpu_app_req), .cpu_is_write(cpu_app_is_write),
    .cpu_grant(cpu_app_grant),
    .cpu_wr_en(cpu_app_wr_en), .cpu_wr_addr(cpu_app_wr_addr),
    .cpu_wr_dm(cpu_app_wr_dm), .cpu_wr_din(cpu_app_wr_din),
    .cpu_rd_en(cpu_app_rd_en), .cpu_rd_addr(cpu_app_rd_addr),
    .cpu_rd_valid(cpu_sdr_rd_en), .sdr_rd_valid(sdr_rd_en),
    .app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr),
    .app_wr_dm(app_wr_dm), .app_wr_din(app_wr_din),
    .app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr)
);

sdram_ctrl u_sdram_ctrl (
    .clk(mem_clk), .clk_sft(mem_clk_sft), .rst(rst_all),
    .sdr_init_done(sdr_init_done), .sdr_init_ref_vld(sdr_init_ref_vld),
    .sdr_busy(sdr_busy), .app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr),
    .app_wr_dm(app_wr_dm), .app_wr_din(app_wr_din), .app_rd_en(app_rd_en),
    .app_rd_addr(app_rd_addr), .sdr_rd_en(sdr_rd_en), .sdr_rd_dout(sdr_rd_dout)
);

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        vs_d1 <= 1'b0; de_d1 <= 1'b0; frame_arm <= 1'b1; x_cnt <= 11'd0;
        axis_s_user <= 1'b0; axis_s_valid <= 1'b0; axis_s_last <= 1'b0;
        axis_s_data <= 24'd0;
    end else begin
        vs_d1 <= player_vs;
        de_d1 <= player_de;
        axis_s_user <= 1'b0;
        axis_s_valid <= player_de;
        axis_s_last <= 1'b0;
        axis_s_data <= player_output;
        if (vs_d1 != player_vs)
            frame_arm <= 1'b1;
        if (player_de) begin
            if (!de_d1) begin
                x_cnt <= 11'd0;
                axis_s_user <= frame_arm;
                frame_arm <= 1'b0;
            end else begin
                x_cnt <= x_cnt + 1'b1;
            end
            if (x_cnt == H_ACTIVE_LAST)
                axis_s_last <= 1'b1;
        end else begin
            x_cnt <= 11'd0;
        end
    end
end

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        edid_cnt <= 20'd0;
        edid_done <= 1'b0;
        edid_trig <= 1'b0;
    end else begin
        edid_trig <= 1'b0;
        if (!edid_done) begin
            if (edid_cnt == EDID_TRIG_CYCLES - 1) begin
                edid_done <= 1'b1;
                edid_trig <= 1'b1;
            end else begin
                edid_cnt <= edid_cnt + 1'b1;
            end
        end
    end
end

// ===================== 音频：内部 I2S 音阶（do re mi fa so la si do）=====================
// ---- audio buffer FIFO (write: sd_clk, read: audio_mclk) ----
rfifo_32_32_512 u_audio_fifo (
    .rst        (rst_all),
    .clkw       (sd_clk),
    .clkr       (audio_mclk),
    .we         (aud_wr_en),
    .di         (aud_wr_data),
    .re         (aud_fifo_re),
    .dout       (aud_fifo_dout),
    .valid      (),
    .full_flag  (),
    .empty_flag (aud_fifo_empty),
    .afull      (),
    .aempty     (),
    .wrusedw    (aud_wrusedw),
    .rdusedw    ()
);

// ---- wav player: FIFO -> I2S ----
wav_player_i2s u_wav_player (
    .I_mclk       (audio_mclk),
    .I_rst        (rst_all | ~audio_pll_lock),
    .I_fifo_dout  (aud_fifo_dout),
    .I_fifo_empty (aud_fifo_empty),
    .O_fifo_re    (aud_fifo_re),
    .O_i2s_BCLK   (pl_bclk),
    .O_i2s_LRCK   (pl_lrck),
    .O_i2s_DOUT   (pl_dout)
);

hdmi_audio_tone_i2s_64fs #(
    .PHASE_INC (32'd39370534),
    .AMP       (24'sd2000000)
) u_audio_tone (
    .I_mclk     (audio_mclk),
    .I_rst      (rst_all | ~audio_pll_lock),   // 音频 PLL 未锁定前保持复位
    .O_i2s_BCLK (tone_bclk),
    .O_i2s_LRCK (tone_lrck),
    .O_i2s_DOUT (tone_dout)
);

// once the song starts streaming, use the player; otherwise use the tone
always @(posedge audio_mclk or posedge rst_all) begin
    if (rst_all)              aud_seen <= 1'b0;
    else if (!aud_fifo_empty) aud_seen <= 1'b1;
end

assign i2s_bclk_sel = aud_seen ? pl_bclk : tone_bclk;
assign i2s_lrck_sel = aud_seen ? pl_lrck : tone_lrck;
assign i2s_dout_sel = aud_seen ? pl_dout : tone_dout;

I2S_receiver u_I2S_receiver (
    .I_clk              (video_clk),
    .I_rst              (rst_all),
    .I_i2s_BCLK         (i2s_bclk_sel),
    .I_i2s_LRCK         (i2s_lrck_sel),
    .I_i2s_DOUT         (i2s_dout_sel),
    .O_audio_valid      (audio_valid),
    .O_audio_left_data  (audio_left_data),
    .O_audio_right_data (audio_right_data)
);

audio_tone_control u_audio_tone_control (
    .clk(video_clk),.rst(rst_all),.in_valid(audio_valid),
    .left_in(audio_left_data),.right_in(audio_right_data),
    .volume(cpu_audio_settings[3:0]),.bass(cpu_audio_settings[6:4]),
    .treble(cpu_audio_settings[9:7]),.mute(cpu_audio_settings[10]),
    .out_valid(audio_valid_eq),.left_out(audio_left_eq),
    .right_out(audio_right_eq)
);

audio_start_gate u_audio_start_gate (
    .clk(video_clk),.rst(rst_all),.controlled(music_controlled),
    .left_in(audio_left_eq),.right_in(audio_right_eq),
    .left_out(audio_left_ready),.right_out(audio_right_ready)
);

audio_arc_calculate #(
    .ACR_N (6144)
) u_audio_arc (
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_audio_valid (audio_valid_eq),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE("EG"), .HTOTAL(800), .HSA(96), .HFP(16), .HBP(48), .HACTIVE(640),
    .VTOTAL(525), .VSA(2), .VFP(10), .VBP(33), .VACTIVE(480),
    .VIDEO_TPG("Disable"), .VIDEO_FORMAT("RGB"), .VIDEO_VIC(1),
    .AUDIO_SAMPLE_RATE("48K"), .IIC_SCL_DIV(250)
) u_hdmi_core (
    .I_pixel_clk(video_clk), .I_rst(rst_all), .I_edid_read_trig(edid_trig),
    .O_edid_read_valid(edid_valid), .O_edid_read_data(edid_data),
    .I_axis_s_user(axis_s_user), .I_axis_s_valid(axis_s_valid),
    .I_axis_s_last(axis_s_last), .I_axis_s_data(axis_s_data),
    .O_axis_s_ready(axis_s_ready),
    .I_audio_valid(audio_valid_eq),
    .I_audio_left_data(audio_left_ready), .I_audio_right_data(audio_right_ready),
    .I_acr_valid(acr_valid), .I_acr_cts(acr_cts), .I_acr_n(acr_n), .O_video_locked(),
    .O_ddc_scl(HDMI_DDC_SCL), .IO_ddc_sda(HDMI_DDC_SDA),
    .O_ch0_tmds_data(tmds_ch0_data), .O_ch1_tmds_data(tmds_ch1_data),
    .O_ch2_tmds_data(tmds_ch2_data), .O_clk_tmds_data(tmds_clk_data)
);

hdmi_phy_wrapper #(.DEVICE("EG")) u_hdmi_phy (
    .I_pixel_clk(video_clk), .I_serial_clk(hdmi_5x_clk), .I_rst(rst_all),
    .I_tmds_channel_0(tmds_ch0_data), .I_tmds_channel_1(tmds_ch1_data),
    .I_tmds_channel_2(tmds_ch2_data), .I_tmds_channel_clk(tmds_clk_data),
    .O_tmds_ch0_p(HDMI_D0_P), .O_tmds_ch1_p(HDMI_D1_P),
    .O_tmds_ch2_p(HDMI_D2_P), .O_tmds_clk_p(HDMI_CLK_P)
);

endmodule
