// -----------------------------------------------------------------------------
// audio_scope：音频可视化（双声道电平律动柱）
//
//   全部在视频时钟域：直接吃 top.v 里 I2S_receiver 已经收好的
//   O_audio_valid / O_audio_left_data / O_audio_right_data（本来就是 video_clk 域），
//   所以这里没有任何跨时钟域逻辑——不用握手，也没有 hold/时序隐患。
//
//   每个视频帧把样本切成 SLICES 个时间片取峰值（8bit）：左半屏跟左声道、
//   右半屏跟右声道，在屏幕底部 Y_TOP..Y_BOT 画 BARS 根柱，最底一行常亮当基线
//
//   说明：这是"包络律动柱"，不是 FFT 频谱（FFT 要乘加器，LUT/DSP 余量不值当）
// -----------------------------------------------------------------------------
module audio_scope #(
    parameter integer BARS          = 32,        // 柱子总数（左半 BARS/2 + 右半 BARS/2）
    parameter integer BAR_W         = 20,        // 每根柱占的像素宽度（BARS*BAR_W = 帧宽）
    parameter integer SLICES        = 16,        // 每声道时间片数（= BARS/2）
    parameter integer SAMP_PER_SLICE= 50,        // 48kHz / 60Hz / SLICES = 50 个样本一片
    parameter integer Y_TOP         = 356,       // 柱区顶行（含），在字幕底条下面
    parameter integer Y_BOT         = 477        // 柱区底行（含），基线画在这行
)(
    input  wire        clk,           // 视频时钟（25MHz）
    input  wire        rst,
    input  wire        en,            // 1 = 正在放歌（放开机测试音时不画）
    input  wire        samp_valid,    // I2S 收到一帧立体声（约 48kHz）
    input  wire [23:0] samp_l,        // 左声道（有符号 24bit，取高 16 位用）
    input  wire [23:0] samp_r,
    input  wire        vs,
    input  wire        de,
    output reg         scope_on,      // 1 = 该像素属于律动柱
    output reg  [23:0] scope_rgb,
    output wire [95:0] ui_levels
);

localparam integer HALF    = BARS / 2;
localparam [5:0]   STRIP_H = Y_BOT - Y_TOP + 1;   // 柱区高度（行数）

// 颜色：底部绿 → 中间黄 → 顶部红（跟电平高度对应）
localparam [23:0] COL_LOW  = 24'h00E020;
localparam [23:0] COL_MID  = 24'hFFD800;
localparam [23:0] COL_HIGH = 24'hFF2000;

// ============================ 电平提取 ============================
reg [7:0] acc_l [0:SLICES-1];        // 本帧左声道各时间片峰值
reg [7:0] acc_r [0:SLICES-1];
reg [7:0] lvl [0:BARS-1];            // 显示用电平（前 HALF 个 = 左声道）
reg [4:0] sl_cnt;                    // 时间片序号
reg [5:0] smp_cnt;                   // 片内样本计数
reg       vs_d;                      // 场同步打一拍（找帧边界）

// |x|：24bit 有符号 -> 16bit 幅度（低 8 位是 I2S 补的 0，取高 16 位就够）
wire [15:0] mag_l = samp_l[23] ? (~samp_l[23:8] + 16'd1) : samp_l[23:8];
wire [15:0] mag_r = samp_r[23] ? (~samp_r[23:8] + 16'd1) : samp_r[23:8];

genvar ui_bar;
generate
    for (ui_bar = 0; ui_bar < 6; ui_bar = ui_bar + 1) begin : g_ui_levels
        assign ui_levels[ui_bar*8 +: 8] = lvl[ui_bar*3];
        assign ui_levels[(ui_bar+6)*8 +: 8] = lvl[HALF + ui_bar*3];
    end
endgenerate

integer ai;
wire frame_tick = vs & ~vs_d;        // 新帧开始（与坐标计数用的是同一拍沿）

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sl_cnt  <= 5'd0;
        smp_cnt <= 6'd0;
        for (ai = 0; ai < SLICES; ai = ai + 1) begin
            acc_l[ai] <= 8'd0;
            acc_r[ai] <= 8'd0;
            lvl[ai]           <= 8'd0;
            lvl[SLICES + ai]  <= 8'd0;
        end
    end else if (frame_tick) begin
        // 新帧：把上一帧攒的峰值搬进显示寄存器，累加器清零（同一个 always，避免多驱动）
        for (ai = 0; ai < SLICES; ai = ai + 1) begin
            lvl[ai]           <= acc_l[ai];
            lvl[SLICES + ai]  <= acc_r[ai];
            acc_l[ai]         <= 8'd0;
            acc_r[ai]         <= 8'd0;
        end
        sl_cnt  <= 5'd0;
        smp_cnt <= 6'd0;
    end else if (samp_valid && en) begin
        if (mag_l[15:8] > acc_l[sl_cnt])
            acc_l[sl_cnt] <= mag_l[15:8];
        if (mag_r[15:8] > acc_r[sl_cnt])
            acc_r[sl_cnt] <= mag_r[15:8];

        if (smp_cnt == SAMP_PER_SLICE - 1) begin
            smp_cnt <= 6'd0;
            if (sl_cnt != SLICES - 1)
                sl_cnt <= sl_cnt + 5'd1;      // 满了就停在最后一片，不回头覆盖
        end else begin
            smp_cnt <= smp_cnt + 6'd1;
        end
    end
end

// ============================ 视频域 ============================
// de 每行正好 640 个有效像素，坐标自己数即可
reg [9:0]  px;
reg [8:0]  py;
reg        de_d;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        px    <= 10'd0;
        py    <= 9'd0;
        vs_d  <= 1'b0;
        de_d  <= 1'b0;
    end else begin
        vs_d <= vs;
        de_d <= de;
        if (vs_d != vs)
            py <= 9'd0;
        else if (de_d && !de)
            // 行尾再 +1：这样整条有效行里 py 都等于当前行号
            //（用行首 +1 会让每行第一个像素还拿着上一行的行号）
            py <= py + 9'd1;
        if (de)
            px <= px + 10'd1;
        else
            px <= 10'd0;
    end
end

reg [7:0]  lvl_q;                    // 寄存读出的电平

// 柱序号与柱内像素位置（用计数器，避免除以 20）
reg [5:0] bar_px;                    // 0..BAR_W-1
reg [5:0] bar_idx;                   // 0..BARS-1

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bar_px <= 6'd0;
        bar_idx<= 6'd0;
    end else if (de) begin
        if (bar_px == BAR_W - 1) begin
            bar_px  <= 6'd0;
            bar_idx <= (bar_idx == BARS - 1) ? 6'd0 : (bar_idx + 6'd1);
        end else begin
            bar_px <= bar_px + 6'd1;
        end
    end else begin
        bar_px  <= 6'd0;
        bar_idx <= 6'd0;
    end
end

// 坐标与电平读数据对齐：px_d/py_d 与 vout_data 同拍，电平地址提前一拍发
reg [9:0] px_d;
reg [8:0] py_d;
reg       de_d_d;
reg [5:0] bar_px_d;                 // 与 px_d 同拍，柱内位置（画缝用）

always @(posedge clk or posedge rst) begin
    if (rst) begin
        px_d    <= 10'd0;
        py_d    <= 9'h1FF;
        de_d_d  <= 1'b0;
        lvl_q   <= 8'd0;
        bar_px_d<= 6'd0;
    end else begin
        px_d    <= px;
        py_d    <= py;
        de_d_d  <= de;
        bar_px_d<= bar_px;
        lvl_q   <= lvl[bar_idx];     // 寄存读（TD 认成小 RAM/逻辑，32 项不贵）
    end
end

// ---- 画柱：底部基线常亮，柱高 = 电平 >> LEVEL_SH ----
// 对数式（近似 dB）映射：8bit 电平 -> 柱高，每翻一倍幅度多加一大格，
// 这样典型音乐电平能到柱区一半以上（线性映射时只有 4 行，看着像没动）
wire [6:0] raw_h  = {lvl_q[7:5], 4'b0000} |        // 大格：每 2 倍幅度 +16 行
                    (lvl_q[4] ? 7'd8  : 7'd0) |    // 中格
                    (lvl_q[3] ? 7'd4  : 7'd0);     // 小格（安静时也有小起伏）
wire [6:0] bar_h  = (raw_h > STRIP_H) ? STRIP_H : raw_h;
wire [8:0] rel    = Y_BOT[8:0] - py_d;                  // 0 = 柱区最底行（柱区已 >64 行，不能用低位取模）
wire       in_zone= de_d_d && (py_d >= Y_TOP[8:0]) && (py_d <= Y_BOT[8:0]);
wire       lit    = (rel < bar_h) || (rel == 6'd0);     // 基线那一行总亮
wire       gap    = (bar_px_d >= BAR_W - 2);            // 每根柱右侧留 2px 缝（对齐延迟坐标）

always @(posedge clk or posedge rst) begin
    if (rst) begin
        scope_on  <= 1'b0;
        scope_rgb <= 24'd0;
    end else begin
        scope_on  <= in_zone && !gap && lit;
        // 颜色按柱区高度分三段（底绿 / 中黄 / 顶红）
        scope_rgb <= (rel < (STRIP_H / 3))         ? COL_LOW :
                     (rel < ((STRIP_H / 3) * 2))   ? COL_MID : COL_HIGH;
    end
end

endmodule
