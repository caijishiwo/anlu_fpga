`timescale 1ns/1ps
// CPU 分别写入参数后提交；SD 扇区结束且歌词空闲时才原子切换。
module riscv_music_control (
    input wire cpu_clk,sd_clk,rst,valid,
    input wire [3:0] wstrb,
    input wire [31:0] addr,wdata,
    output reg ready,
    output reg [31:0] rdata,
    input wire safe_to_switch,finished,
    output reg controlled,restart,
    output reg [31:0] sector,frames,lyric
);
localparam [31:0] MUSIC_ID=32'h4d555331;
reg [31:0] pending_sector,pending_frames,pending_lyric;
reg request_toggle,ack_toggle,error_flag;
reg request_s0,request_s1,ack_s0,ack_s1,finish_s0,finish_s1;
wire busy=request_toggle!=ack_s1;
always @(posedge cpu_clk or posedge rst) begin
    if(rst) begin
        ready<=0;pending_sector<=0;pending_frames<=0;pending_lyric<=0;
        request_toggle<=0;ack_s0<=0;ack_s1<=0;finish_s0<=0;finish_s1<=0;error_flag<=0;
    end else begin
        ready<=valid && !ready;
        ack_s0<=ack_toggle;ack_s1<=ack_s0;
        finish_s0<=finished;finish_s1<=finish_s0;
        if(valid && !ready && (|wstrb)) begin
            if(busy || wstrb!=4'b1111) error_flag<=1;
            else case(addr[7:0])
                8'h00:pending_sector<=wdata;
                8'h04:pending_frames<=wdata;
                8'h08:pending_lyric<=wdata;
                8'h0c:begin request_toggle<=~request_toggle;error_flag<=0;end
                default:error_flag<=1;
            endcase
        end
    end
end
always @(*) begin
    case(addr[7:0])
        8'h10:rdata={29'd0,error_flag,finish_s1,busy};
        8'h18:rdata=MUSIC_ID;
        default:rdata=0;
    endcase
end
always @(posedge sd_clk or posedge rst) begin
    if(rst) begin
        request_s0<=0;request_s1<=0;ack_toggle<=0;
        sector<=0;frames<=0;lyric<=0;controlled<=0;restart<=0;
    end else begin
        request_s0<=request_toggle;request_s1<=request_s0;restart<=0;
        // 等待音频模块实际消费 restart 并清除 finished，再向 CPU 确认。
        if(restart) ack_toggle<=request_s1;
        else if(request_s1!=ack_toggle && safe_to_switch) begin
            sector<=pending_sector;frames<=pending_frames;lyric<=pending_lyric;
            controlled<=1;restart<=1;
        end
    end
end
endmodule
