`timescale 1ns/1ps
// 8档覆盖率：0、1/8、1/4、3/8、1/2、5/8、3/4、完全覆盖。
module overlay_blend (
    input wire [23:0] background, foreground,
    input wire [2:0] coverage,
    output wire [23:0] rgb
);
function [7:0] channel_color;
    input [7:0] base, ink;
    input [2:0] opacity;
    reg signed [8:0] difference;
    reg signed [12:0] weighted;
    begin
        difference=$signed({1'b0,ink})-$signed({1'b0,base});
        weighted=$signed({2'b00,base,3'b000})+
                 difference*$signed({1'b0,opacity});
        case(opacity)
        0:channel_color=base;
        // 保留歌词旧覆盖率的逐通道舍入，避免改变已有字形边缘。
        2:channel_color=(base>>1)+(base>>2)+(ink>>2);
        4:channel_color=(base>>1)+(ink>>1);
        7:channel_color=ink;
        1,3,5,6:channel_color=weighted[10:3];
        default:channel_color=8'bxxxxxxxx;
        endcase
    end
endfunction
genvar channel;
generate for(channel=0;channel<3;channel=channel+1) begin:g_channel
    assign rgb[channel*8+:8]=channel_color(background[channel*8+:8],
        foreground[channel*8+:8],coverage);
end endgenerate
endmodule
