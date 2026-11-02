`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// fx_alpha：切图特效（每次画面变化自动轮换一种，纯视频域像素亮度）
//   0 = 黑场淡入   1 = 从上往下擦除   2 = 中心向上下展开   3 = 百叶窗
//   alpha = 本像素亮度 0..255（0 = 黑）
//   换图后先黑场保持 FX_HOLD 档，再推进 fx_p 到 255（特效播完）
//   不读第二块 bank、不改 SDRAM 通路，只做输出像素缩放
// ---------------------------------------------------------------------------
module fx_alpha #(
    parameter [14:0] FX_TICK = 15'd32767,   // 每档 32768 像素 ≈ 1.31ms @25MHz
    parameter [7:0]  FX_HOLD = 8'd80        // 黑场保持档数 ≈ 105ms
) (
    input  wire        clk,                 // 视频时钟
    input  wire        rst,
    input  wire        de,                  // 显示有效
    input  wire        vs,                  // 场同步
    input  wire        valid,               // 画面有效
    input  wire [5:0]  img_id,              // {图号[3:0], bank[1:0]}
    output reg  [7:0]  alpha
);

localparam [9:0] LINE_MAX = 10'd479;
localparam [9:0] LINE_MID = 10'd240;

reg [9:0]  y_cnt;                           // 当前显示行 0..479
reg        de_d, vs_d;
reg [5:0]  id_s1, id_s2, id_d;
reg        v_d;
reg [14:0] fx_cnt;
reg [7:0]  fx_p;                            // 特效进度 0..255
reg [7:0]  fx_hold;                         // 黑场保持剩余档数
reg [1:0]  fx_idx;                          // 特效编号

wire        fx_done  = (fx_p == 8'hFF);
wire [9:0]  wipe_y   = {fx_p, 1'b0};                              // 0..510
wire [9:0]  mid_dist = (y_cnt > LINE_MID) ? (y_cnt - LINE_MID) : (LINE_MID - y_cnt);
wire [9:0]  p10      = {2'b00, fx_p};
wire        rev_wipe = (y_cnt < wipe_y);
wire        rev_mid  = (mid_dist < p10);
wire        rev_blind= (y_cnt[3:0] < fx_p[7:4]);
wire        revealed = fx_done || ((fx_idx == 2'd1) ? rev_wipe :
                                   (fx_idx == 2'd2) ? rev_mid : rev_blind);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        y_cnt   <= 10'd0;
        de_d    <= 1'b0;
        vs_d    <= 1'b0;
        id_s1   <= 6'd0;
        id_s2   <= 6'd0;
        id_d    <= 6'd0;
        v_d     <= 1'b0;
        fx_cnt  <= 15'd0;
        fx_p    <= 8'hFF;
        fx_hold <= 8'd0;
        fx_idx  <= 2'd0;
        alpha   <= 8'hFF;
    end else begin
        de_d <= de;
        vs_d <= vs;
        id_s1 <= img_id;
        id_s2 <= id_s1;
        id_d  <= id_s2;
        v_d   <= valid;

        // 显示行计数：场同步清零，每个 DE 行 +1
        if (vs_d != vs)
            y_cnt <= 10'd0;
        else if (de && !de_d && (y_cnt != LINE_MAX))
            y_cnt <= y_cnt + 10'd1;

        // 换图 → 换下一种特效，先黑场保持再推进进度
        if (valid && ((id_s2 != id_d) || (valid != v_d))) begin
            fx_hold <= FX_HOLD;
            fx_p    <= 8'd0;
            fx_cnt  <= 15'd0;
            fx_idx  <= fx_idx + 2'd1;
        end else if (fx_hold != 8'd0) begin
            if (fx_cnt == FX_TICK) begin
                fx_cnt  <= 15'd0;
                fx_hold <= fx_hold - 8'd1;
            end else begin
                fx_cnt <= fx_cnt + 15'd1;
            end
        end else if (!fx_done) begin
            if (fx_cnt == FX_TICK) begin
                fx_cnt <= 15'd0;
                fx_p   <= fx_p + 8'd1;
            end else begin
                fx_cnt <= fx_cnt + 15'd1;
            end
        end

        // 本像素亮度
        if (fx_idx == 2'd0)
            alpha <= fx_p;                                    // 黑场淡入
        else if (revealed)
            alpha <= 8'hFF;                                   // 已露出
        else
            alpha <= 8'h00;                                   // 还没露出 → 黑
    end
end

endmodule
