`timescale 1ns/1ps
// 四条原生字形：上一句小字、当前句大字、下一句小字、图片页当前小字。
module lyric_window_loader(
    input wire clk,rst,reload,configured,smooth_format,
    input wire [7:0] nlines,current_line,
    input wire [31:0] data_sector,
    input wire sec_data_valid,sec_end,
    input wire [7:0] sec_data,
    input wire front_ack,
    output reg sec_req,
    output reg [31:0] sec_addr,
    output reg write_enable,write_bank,
    output reg [13:0] write_address,
    output reg [15:0] write_data,
    output reg published,window_ready,
    output reg [3:0] line_mask,
    output reg [43:0] left_bounds,right_bounds,
    output reg [7:0] published_line,
    output reg [3:0] state
);
localparam [3:0] IDLE=0,SLOT=1,ADDRESS=2,BASE=3,VARIANT=4,FETCH=5,NEXT=6,PUBLISH=7,ERROR=15;
localparam [7:0] LINE_NONE=8'hFF;
localparam [10:0] EMPTY_LEFT=11'd1023;
localparam [11:0] SMALL_OFFSET=12'd16;
reg [1:0] slot;
reg [7:0] target,fetch_line,low_byte;
reg [13:0] byte_count;
reg [11:0] line_offset;
reg [10:0] min_x,max_x;
reg ack_m,ack_s,pending;
reg [15:0] pending_word;
reg [13:0] pending_address;
wire [15:0] word_value={sec_data,low_byte};
wire slot_valid=target==LINE_NONE ? slot==2 :
    (slot==0 ? target!=0 : (slot!=2 || {1'b0,target}+1<nlines));
function [13:0] slot_base;
    input [1:0] which;
    begin
        case(which)
        0:slot_base=0;1:slot_base=1536;2:slot_base=5632;3:slot_base=7168;
        endcase
    end
endfunction
function [3:0] first_pixel;
    input [31:0] pixels;
    integer n;
    begin
        first_pixel=15;
        for(n=0;n<16;n=n+1) if(pixels[n*2+:2]!=0) first_pixel=15-n;
    end
endfunction
function [3:0] last_pixel;
    input [31:0] pixels;
    integer n;
    begin
        last_pixel=0;
        for(n=15;n>=0;n=n-1) if(pixels[n*2+:2]!=0) last_pixel=15-n;
    end
endfunction
function [31:0] expand_legacy;
    input [15:0] pixels;
    integer n;
    begin
        for(n=0;n<16;n=n+1) expand_legacy[n*2+:2]={2{pixels[n]}};
    end
endfunction
wire [31:0] expanded=expand_legacy(word_value);
wire [31:0] ink_word=smooth_format ? {word_value,16'd0} : expanded;
wire [10:0] column=smooth_format ?
    (slot==1 ? {byte_count[7:1],3'b0} : {1'b0,byte_count[6:1],3'b0}) :
    {2'b0,byte_count[5:1],4'b0};
wire [10:0] first_x=column+first_pixel(ink_word),last_x=column+last_pixel(ink_word);
wire [13:0] legacy_row=slot==1 ? {3'd0,byte_count[9:6],7'd0} :
    {4'd0,byte_count[9:6],6'd0};
wire [13:0] legacy_address=slot_base(slot)+legacy_row+{8'd0,byte_count[5:1],1'b0};
wire [13:0] plane_bytes=smooth_format ? (slot==1 ? 14'd8192 : 14'd3072) : 14'd1024;
always @(posedge clk or posedge rst) begin
    if(rst) begin ack_m<=0;ack_s<=0;end
    else begin ack_m<=front_ack;ack_s<=ack_m;end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE;sec_req<=0;sec_addr<=0;write_bank<=1;
        published<=0;window_ready<=0;line_mask<=0;
        left_bounds<=0;right_bounds<=0;published_line<=LINE_NONE;slot<=0;
        target<=LINE_NONE;fetch_line<=0;line_offset<=0;
    end else begin
        case(state)
        IDLE: begin
            sec_req<=0;
            if(configured && ack_s==published && (!window_ready || current_line!=published_line)) begin
                target<=current_line;slot<=0;write_bank<=~published;state<=SLOT;
            end
        end
        SLOT: begin
            line_mask[slot]<=slot_valid;
            if(!slot_valid) state<=NEXT;
            else begin
                fetch_line<=target==LINE_NONE ? 0 : (slot==0 ? target-1 :
                    (slot==2 ? target+1 : target));
                state<=ADDRESS;
            end
        end
        ADDRESS: begin
            // 22=16+4+2，先登记12位行偏移，禁止可变乘法串接32位地址加法。
            line_offset<=smooth_format ? ({4'd0,fetch_line}<<4)+({4'd0,fetch_line}<<2)+
                ({4'd0,fetch_line}<<1) : {3'd0,fetch_line,1'b0};
            state<=BASE;
        end
        BASE: begin
            line_offset<=line_offset+(smooth_format && slot!=1 ? SMALL_OFFSET : 12'd0);
            state<=VARIANT;
        end
        VARIANT: begin
            sec_addr<=data_sector+{20'd0,line_offset};
            sec_req<=1;state<=FETCH;
        end
        FETCH: begin
            sec_req<=1;
            if(sec_end) begin
                sec_req<=0;
                if(byte_count==plane_bytes) state<=NEXT;
                else sec_addr<=sec_addr+1'b1;
            end
        end
        NEXT: begin
            left_bounds[slot*11+:11]<=min_x;right_bounds[slot*11+:11]<=max_x;
            if(slot==3) state<=PUBLISH;
            else begin slot<=slot+1'b1;state<=SLOT;end
        end
        PUBLISH: begin
            published_line<=target;published<=~published;window_ready<=1;state<=IDLE;
        end
        ERROR: sec_req<=0;
        default: state<=ERROR;
        endcase
        if(reload || !configured) begin
            state<=IDLE;sec_req<=0;window_ready<=0;
            published<=0;published_line<=LINE_NONE;line_mask<=0;
        end
    end
end
wire word_ready=state==FETCH && sec_data_valid && byte_count[0];
always @(posedge clk or posedge rst) begin
    if(rst) begin byte_count<=0;low_byte<=0;end
    else if(reload || !configured || state==SLOT) byte_count<=0;
    else if(state==FETCH && sec_data_valid) begin
        byte_count<=byte_count+1'b1;
        if(!byte_count[0]) low_byte<=sec_data;
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin min_x<=EMPTY_LEFT;max_x<=0;end
    else if(state==SLOT) begin min_x<=EMPTY_LEFT;max_x<=0;end
    else if(word_ready && word_value!=0) begin
        if(first_x<min_x) min_x<=first_x;
        if(last_x>max_x) max_x<=last_x;
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        write_enable<=0;write_address<=0;write_data<=0;
        pending<=0;pending_word<=0;pending_address<=0;
    end else if(reload || !configured) begin write_enable<=0;pending<=0;end
    else begin
        write_enable<=pending;pending<=0;
        if(pending) begin write_address<=pending_address;write_data<=pending_word;end
        if(word_ready) begin
            write_enable<=1;
            write_address<=smooth_format ? slot_base(slot)+{1'b0,byte_count[13:1]} : legacy_address;
            write_data<=smooth_format ? word_value : expanded[31:16];
            pending<=!smooth_format;pending_address<=legacy_address+1'b1;pending_word<=expanded[15:0];
        end
    end
end
endmodule
