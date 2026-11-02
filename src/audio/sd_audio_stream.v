`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// sd_audio_stream：把音频文件从 SD 卡按扇区读出来，组装成 32bit 帧 {L16,R16}
//   文件布局：第 0 个扇区 = 512B 头（魔数 "ANLUWAV1" + 帧数），
//             从 start_sector+1 开始是裸 PCM（48k/16bit/立体声，每帧 4 字节）
//   与 bmp_read 共用 SD 读口，谁用由 sd_card_bmp 里的仲裁器决定；
//   本模块只负责“发请求 → 收数据 → 写 FIFO”，读完自动从头循环。
// ---------------------------------------------------------------------------
module sd_audio_stream (
    input  wire        clk,              // sd_clk (100MHz)
    input  wire        rst,

    input  wire        enable,           // 扫描到音频文件后使能
    input  wire [31:0] start_sector,     // 音频文件头所在扇区
    input  wire [31:0] frame_count,      // 总帧数
    input  wire [9:0]  fifo_used,        // audio FIFO used words (write clock domain)
    input wire controlled,restart,
    output reg finished,

    // 与仲裁器对接
    output reg         sec_req,
    output      [31:0] sec_addr,
    input  wire        sec_end,          // 本扇区读完（1 拍）
    input  wire        sec_data_valid,   // 本扇区数据有效
    input  wire [7:0]  sec_data,

    // 写 FIFO
    output reg         wr_en,
    output reg  [31:0] wr_data,

    output reg  [31:0] dbg_sectors,
    output reg  [31:0] frames_played      // 已播放帧号（字幕按它对齐时间轴）
);


reg  [1:0]  byte_idx;
reg  [31:0] cur_sector;
reg  [31:0] data_sectors;
reg  [31:0] frames_left;
reg         active;
reg  [31:0] sectors_done;
reg  [31:0] start_sector_d;      // 上一拍的音频位置/长度，用于检测"换了文件"
reg  [31:0] frame_count_d;
reg         pass_done;           // 本轮最后一帧已读完，等当前扇区收尾后回头

wire [31:0] total_bytes  = {frame_count[29:0], 2'b00};              // frame_count*4
wire [31:0] data_secs    = (total_bytes + 32'd511) >> 9;            // 数据扇区数
reg  [31:0] file_sectors_r;   // 寄存版：避免"移位+两级加法"串进数据通路
always @(posedge clk or posedge rst) begin
    if (rst) file_sectors_r <= 32'd0;
    else     file_sectors_r <= data_secs + 32'd1;
end                       // + 头扇区

// 需要重新装载播放状态的三种情况：
//   1) 还没使能 / 未知长度
//   2) 刚复位或上一轮刚结束（frames_left=0 且还没读过扇区）
//   3) 音频文件位置或长度变了（bmp_read 会与 enable 同拍更新，必须能识别）
wire audio_reload_w = !enable || (frame_count == 32'd0) ||
                      ((frames_left == 32'd0) && (sectors_done == 32'd0)) ||
                      (start_sector != start_sector_d) || (frame_count != frame_count_d);
// 重载判定打一拍：原路径是 frame_count 的 32 位比较 -> 或树 -> 十几个寄存器的
// 数据/使能 mux，100MHz 下 11.2ns（布线占 56%）。寄存后 frame_count 只走到比较器，
// 代价是重载晚一拍发生，对音频循环播放无影响。
reg audio_reload;
always @(posedge clk or posedge rst) begin
    if (rst) audio_reload <= 1'b0;
    else     audio_reload <= audio_reload_w;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sec_req      <= 1'b0;
        wr_en        <= 1'b0;
        wr_data      <= 32'd0;
        byte_idx     <= 2'd0;
        cur_sector   <= 32'd0;
        data_sectors <= 32'd0;
        frames_left  <= 32'd0;
        active       <= 1'b0;
        sectors_done <= 32'd0;
        dbg_sectors  <= 32'd0;
        frames_played <= 32'd0;
        start_sector_d <= 32'd0;
        frame_count_d  <= 32'd0;
        pass_done      <= 1'b0;
        finished       <= 1'b0;
    end else begin
        wr_en <= 1'b0;
        start_sector_d <= start_sector;
        frame_count_d  <= frame_count;
        // 播放位置 = 总帧数 - 剩余帧数（读卡领先 FIFO 深度 ≈ 8ms，对字幕无影响）
        frames_played <= (frames_left >= frame_count) ? 32'd0
                                                      : (frame_count - frames_left);

        if (audio_reload || restart) begin
            sec_req      <= 1'b0;
            active       <= 1'b0;
            byte_idx     <= 2'd0;
            cur_sector   <= start_sector + 32'd1;   // 头占 1 个扇区
            data_sectors <= file_sectors_r;
            frames_left  <= frame_count;
            sectors_done <= 32'd0;
            pass_done    <= 1'b0;
            finished     <= 1'b0;
        end else begin
            // 需要更多数据就请求一个音频扇区（保持请求，直到该扇区读完）
            if (!finished && !pass_done && !active && (frames_left != 32'd0) && (fifo_used < 10'd384))
                sec_req <= 1'b1;

            if (sec_data_valid && (frames_left != 32'd0) && !pass_done) begin
                case (byte_idx)
                    2'd0: wr_data[7:0]   <= sec_data;
                    2'd1: wr_data[15:8]  <= sec_data;
                    2'd2: wr_data[23:16] <= sec_data;
                    default: begin
                        wr_data[31:24] <= sec_data;
                        wr_en          <= 1'b1;      // 4 字节凑成一帧
                    end
                endcase
                byte_idx <= (byte_idx == 2'd3) ? 2'd0 : (byte_idx + 2'd1);
                if (byte_idx == 2'd3) begin
                    if (frames_left == 32'd1) begin
                        // 本轮最后一帧读完：不再请求新扇区，等当前扇区收尾。
                        // 千万不能"再多读一个扇区等 sec_end"——那个扇区已经是文件
                        // 后面的垃圾数据，当 PCM 播出来就是一段很吵的噪声。
                        pass_done <= 1'b1;
                    end else begin
                        frames_left <= frames_left - 32'd1;
                    end
                end
            end

            if (sec_data_valid)
                active <= 1'b1;

            if (sec_end) begin
                sec_req      <= 1'b0;
                active       <= 1'b0;
                byte_idx     <= 2'd0;
                sectors_done <= sectors_done + 32'd1;
                dbg_sectors  <= dbg_sectors + 32'd1;
                if (pass_done || (frames_left == 32'd0) ||
                    (sectors_done + 32'd1 >= file_sectors_r)) begin
                    if(controlled) begin
                        finished<=1'b1;
                        frames_left<=0;
                    end else begin
                        cur_sector<=start_sector+32'd1;
                        frames_left<=frame_count;
                        sectors_done<=0;
                        pass_done<=0;
                    end
                end else begin
                    cur_sector <= cur_sector + 32'd1;
                end
            end
        end
    end
end

assign sec_addr = cur_sector;

endmodule
