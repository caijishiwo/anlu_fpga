`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// wav_player_i2s：把 FIFO 里的 32bit 帧 {L16,R16} 按 64fs I2S 发出去
//   MCLK  = 12.295MHz（音频 PLL C2）
//   BCLK  = MCLK/2  ≈ 6.1475MHz
//   LRCK  = MCLK/256 ≈ 48.03kHz（每声道 64bit，采样放在高 24 位）
//   与 I2S_receiver 完全兼容（时序同官方 hdmi_audio_tone_i2s_64fs）
//   FIFO 空时输出静音（0），不会卡住
// ---------------------------------------------------------------------------
module wav_player_i2s (
    input  wire        I_mclk,
    input  wire        I_rst,

    input  wire [31:0] I_fifo_dout,
    input  wire        I_fifo_empty,
    output reg         O_fifo_re,

    output reg         O_i2s_BCLK,
    output reg         O_i2s_LRCK,
    output reg         O_i2s_DOUT
);

reg  [5:0]  S_bit_cnt;
reg  [63:0] S_shift_reg;
reg  [15:0] S_left;
reg  [15:0] S_right;
reg  [31:0] S_frame;
reg         S_re_d;
reg         S_need_frame;

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        O_i2s_BCLK  <= 1'b0;
        O_i2s_LRCK  <= 1'b0;
        O_i2s_DOUT  <= 1'b0;
        O_fifo_re   <= 1'b0;
        S_bit_cnt   <= 6'd0;
        S_shift_reg <= 64'd0;
        S_left      <= 16'd0;
        S_right     <= 16'd0;
        S_frame     <= 32'd0;
        S_re_d      <= 1'b0;
        S_need_frame<= 1'b0;
    end else begin
        O_i2s_BCLK <= ~O_i2s_BCLK;
        O_fifo_re  <= 1'b0;
        S_re_d     <= O_fifo_re;

        // FIFO 读出的下一拍收货（NOREG/OUTREG 都兼容）
        if (S_re_d)
            S_frame <= I_fifo_dout;
        else if (S_need_frame && I_fifo_empty)
            S_frame <= 32'd0;            // 欠载 → 静音

        if (O_i2s_BCLK == 1'b1) begin
            O_i2s_DOUT  <= S_shift_reg[63];
            S_shift_reg <= {S_shift_reg[62:0], 1'b0};

            if (S_bit_cnt == 6'd63) begin
                S_bit_cnt <= 6'd0;
                if (O_i2s_LRCK == 1'b0) begin
                    // 左声道发完 → 发右声道
                    O_i2s_LRCK  <= 1'b1;
                    S_shift_reg <= {S_right, 8'h00, 40'd0};
                end else begin
                    // 右声道发完 → 进入下一帧：装左声道，并去 FIFO 取下一帧
                    O_i2s_LRCK   <= 1'b0;
                    S_left       <= S_frame[31:16];
                    S_right      <= S_frame[15:0];
                    S_shift_reg  <= {S_frame[31:16], 8'h00, 40'd0};
                    S_need_frame <= 1'b1;
                end
            end else begin
                S_bit_cnt <= S_bit_cnt + 6'd1;
                S_need_frame <= 1'b0;
            end

            // 该取下一帧了：FIFO 非空就发读请求
            if (S_need_frame && !I_fifo_empty)
                O_fifo_re <= 1'b1;
        end
    end
end

endmodule
