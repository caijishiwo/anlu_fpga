`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// uart_log：把内部调试状态用串口按行打印（115200 8N1，依赖 al_ip/UART_0）
//   每 0.5 秒打印一行；检测到按键时立刻补打一行。
//   格式：ST=x F=xx C=x S=x L=x P=x K=xx T=xx SEC=xxxxxxxx RD=xxxx D=x
//         L=xx A=xxxxxxxx V=x Y=x\r\n
//     ST = bmp_read 状态码（1=空闲 2=扫描或读文件头 3=等写入 4=读图像数据 7=解析文件系统）
//     F  = 扫描到的图片张数     C = 当前显示第几张
//     S  = 扫描结果有效         L = 出现过加载失败
//     P  = 预加载完成           K = 按键被识别的次数
//     T  = 文件系统识别结果（高 4 位：0/1/2；低 4 位：每簇扇区数的 log2）
//     D  = 目录法诊断（bit3 目录起点生效 / bit2 找到 MUSIC / bit1 找到 PICTURE / bit0 找到音频）
//     L  = 当前歌词行号（FF = 没有字幕）
//     A  = 音频播放帧号（48000 帧/秒，不变说明歌没在放）
//     V  = 是否找到字幕文件 LYRIC.BIN
//     Y  = 字幕状态：0等文件 1读头 2读索引 3待命 4选行 5取行 6清空
// ---------------------------------------------------------------------------
module uart_log (
    input  wire        clk,          // 50 MHz
    input  wire        rst_n,
    input  wire [3:0]  state_code,
    input  wire [17:0] info,         // {found[5:0],scan_valid,load_failed,preload_done,cur_img[4:0],key_cnt[3:0]}
    input  wire        key_pulse,
    input  wire [31:0] scan_sector,  // 当前扫描扇区
    input  wire [15:0] read_cnt,     // 已完成扇区读次数
    input  wire [7:0]  fs_kind,      // {文件系统[7:4]: 0未识别 1FAT 2exFAT, 每簇扇区数log2[3:0]}
    input  wire [3:0]  dir_flags,    // {目录起点生效, 找到MUSIC, 找到PICTURE, 找到音频}
    input  wire [7:0]  lyric_line,   // 当前歌词行号（0xFF = 无字幕）
    input  wire [31:0] audio_frame,  // 当前播放帧号
    input  wire        lyric_valid,  // 找到 LYRIC.BIN
    input  wire [3:0]  lyric_state,  // 字幕模块状态
    input  wire        rxd,
    output wire        txd
);

localparam integer T_LINE = 25_000_000;      // 0.5s @50MHz

reg        tx_en;
reg  [7:0] tx_data;
wire       tx_rdy;

reg  [6:0] idx;
reg  [31:0] wait_cnt;
reg        sending;
reg        tx_rdy_d;        // tx_rdy 打一拍，用于"只在 ready 上升沿发一个字节"
reg        first_byte;      // 一行/一段的第一个字节允许立即发
reg  [7:0] banner_cnt;

UART_0 u_uart (
    .clk    (clk),
    .rst_n  (rst_n),
    .rx_vld (),
    .rx_data(),
    .rx_err (),
    .rxd    (rxd),
    .tx_rdy (tx_rdy),
    .tx_en  (tx_en),
    .tx_data(tx_data),
    .txd    (txd)
);

function [7:0] hexc;
    input [3:0] v;
    begin
        hexc = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h41 + {4'd0, v} - 8'd10);
    end
endfunction

wire [5:0] found   = info[17:12];
wire [4:0] cur_img = info[8:4];
wire [3:0] key_cnt = info[3:0];

// 一行固定 58 个可见/控制字符
function [7:0] line_char;
    input [6:0] i;
    begin
        case (i)
            6'd0 : line_char = "S";
            6'd1 : line_char = "T";
            6'd2 : line_char = "=";
            6'd3 : line_char = hexc(state_code[3:0]);
            6'd4 : line_char = " ";
            6'd5 : line_char = "F";
            6'd6 : line_char = "=";
            6'd7 : line_char = hexc(found[3:0]);
            6'd8 : line_char = hexc({2'd0, found[5:4]});
            6'd9 : line_char = " ";
            6'd10: line_char = "C";
            6'd11: line_char = "=";
            6'd12: line_char = hexc({3'd0, cur_img[4]});
            6'd13: line_char = hexc(cur_img[3:0]);
            6'd14: line_char = " ";
            6'd15: line_char = "S";
            6'd16: line_char = "=";
            6'd17: line_char = info[11] ? "1" : "0";
            6'd18: line_char = " ";
            6'd19: line_char = "L";
            6'd20: line_char = "=";
            6'd21: line_char = info[10] ? "1" : "0";
            6'd22: line_char = " ";
            6'd23: line_char = "P";
            6'd24: line_char = "=";
            6'd25: line_char = info[9] ? "1" : "0";
            6'd26: line_char = " ";
            6'd27: line_char = "K";
            6'd28: line_char = "=";
            6'd29: line_char = hexc(key_cnt);
            6'd30: line_char = " ";
            6'd31: line_char = "T";
            6'd32: line_char = "=";
            6'd33: line_char = hexc(fs_kind[7:4]);
            6'd34: line_char = hexc(fs_kind[3:0]);
            6'd35: line_char = " ";
            6'd36: line_char = "S";
            6'd37: line_char = "E";
            6'd38: line_char = "C";
            6'd39: line_char = "=";
            6'd40: line_char = hexc(scan_sector[31:28]);
            6'd41: line_char = hexc(scan_sector[27:24]);
            6'd42: line_char = hexc(scan_sector[23:20]);
            6'd43: line_char = hexc(scan_sector[19:16]);
            6'd44: line_char = hexc(scan_sector[15:12]);
            6'd45: line_char = hexc(scan_sector[11:8]);
            6'd46: line_char = hexc(scan_sector[7:4]);
            6'd47: line_char = hexc(scan_sector[3:0]);
            6'd48: line_char = " ";
            6'd49: line_char = "R";
            6'd50: line_char = "D";
            6'd51: line_char = "=";
            6'd52: line_char = hexc(read_cnt[15:12]);
            6'd53: line_char = hexc(read_cnt[11:8]);
            6'd54: line_char = hexc(read_cnt[7:4]);
            6'd55: line_char = hexc(read_cnt[3:0]);
            6'd56: line_char = " ";
            6'd57: line_char = "D";
            6'd58: line_char = "=";
            6'd59: line_char = hexc(dir_flags);
            6'd60: line_char = " ";
            6'd61: line_char = "L";
            6'd62: line_char = "=";
            7'd63: line_char = hexc(lyric_line[7:4]);
            7'd64: line_char = hexc(lyric_line[3:0]);
            7'd65: line_char = " ";
            7'd66: line_char = "A";
            7'd67: line_char = "=";
            7'd68: line_char = hexc(audio_frame[31:28]);
            7'd69: line_char = hexc(audio_frame[27:24]);
            7'd70: line_char = hexc(audio_frame[23:20]);
            7'd71: line_char = hexc(audio_frame[19:16]);
            7'd72: line_char = hexc(audio_frame[15:12]);
            7'd73: line_char = hexc(audio_frame[11:8]);
            7'd74: line_char = hexc(audio_frame[7:4]);
            7'd75: line_char = hexc(audio_frame[3:0]);
            7'd76: line_char = " ";
            7'd77: line_char = "V";
            7'd78: line_char = "=";
            7'd79: line_char = lyric_valid ? "1" : "0";
            7'd80: line_char = " ";
            7'd81: line_char = "Y";
            7'd82: line_char = "=";
            7'd83: line_char = hexc(lyric_state);
            7'd84: line_char = 8'h0D;
            7'd85: line_char = 8'h0A;
            default: line_char = 8'h00;
        endcase
    end
endfunction

// 上电横幅：连发 64 个 'U'（0x55，方波），方便确认波特率/接线
wire [7:0] send_char = (banner_cnt < 8'd64) ? 8'h55 : line_char(idx);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_en    <= 1'b0;
        tx_data  <= 8'd0;
        idx      <= 6'd0;
        wait_cnt <= 32'd0;
        sending  <= 1'b0;
        tx_rdy_d <= 1'b0;
        first_byte <= 1'b0;
        banner_cnt <= 8'd0;
    end else begin
        tx_en <= 1'b0;
        tx_rdy_d <= tx_rdy;
        if (!sending) begin
            // 等间隔；按键时立刻补一行
            if ((wait_cnt >= T_LINE) || key_pulse) begin
                wait_cnt <= 32'd0;
                idx      <= 6'd0;
                sending  <= 1'b1;
                first_byte <= 1'b1;
            end else begin
                wait_cnt <= wait_cnt + 32'd1;
            end
        end else if (tx_rdy && (first_byte || !tx_rdy_d)) begin
            tx_en   <= 1'b1;
            tx_data <= send_char;
            first_byte <= 1'b0;
            if (banner_cnt < 8'd64) begin
                banner_cnt <= banner_cnt + 8'd1;
            end else if (idx >= 7'd85)
                sending <= 1'b0;
            else
                idx <= idx + 7'd1;
        end
    end
end

endmodule
