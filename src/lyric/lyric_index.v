`timescale 1ns/1ps
// 显式支持已有ANLULYR1单色及ANLULYR2原生双字号A2格式。
module lyric_index #(parameter [31:0] CHECK_DIV=32'd1000000)(
    input wire clk,rst,reload,file_valid,
    input wire [31:0] file_start_sector,play_frame,
    input wire sec_data_valid,sec_end,
    input wire [7:0] sec_data,
    output reg sec_req,
    output reg [31:0] sec_addr,
    output reg configured,
    output reg smooth_format,
    output wire [7:0] nlines,
    output reg [7:0] current_line,
    output reg [31:0] data_sector,
    output reg [3:0] state
);
localparam [3:0] IDLE=0,HEADER=1,VALIDATE=2,INDEX=3,WAIT=4,SCAN=5,ERROR=15;
localparam [7:0] LINE_NONE=8'hFF;
localparam [63:0] MAGIC=64'h3152594C554C4E41;
localparam [7:0] MAX_LINES=128,INDEX_FIRST_CAPACITY=112;
reg [31:0] base_sector,offset;
reg [7:0] count;
reg header_bad;
reg [9:0] byte_count;
reg [7:0] index_count,scan_count,scan_line;
reg [31:0] assembled,previous_timestamp,timer,scan_frame;
reg scan_valid;
reg [7:0] scan_address_d;
wire [31:0] timestamp_read;
reg index_invalid;
assign nlines=count[7:0];
wire [31:0] timestamp_word={sec_data,assembled[31:8]};
wire magic_byte_valid=byte_count<7 ? sec_data==MAGIC[byte_count[2:0]*8+:8] :
    (sec_data=="1" || sec_data=="2");
// 512字节对齐后，用扇区位判断>=512/1024，避免行数比较再串联32位比较。
wire index_space_valid=(|offset[31:10]) || (offset[9] && count<=INDEX_FIRST_CAPACITY);
wire header_valid=!header_bad && count!=0 && count<=MAX_LINES &&
    offset[8:0]==0 && index_space_valid;
wire timestamp_write=state==INDEX && sec_data_valid && byte_count>=64 &&
    index_count<count && byte_count[1:0]==3 && !reload && file_valid;
wire timestamp_fetch=state==SCAN && scan_count<count && !reload && file_valid;
// 固定映射至两块9K RAM；索引完整装载后才扫描，未装载位置不会被读取。
EG_LOGIC_BRAM #(.DATA_WIDTH_A(32),.DATA_WIDTH_B(32),
    .ADDR_WIDTH_A(7),.ADDR_WIDTH_B(7),.DATA_DEPTH_A(128),.DATA_DEPTH_B(128),
    .MODE("PDPW"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),
    .IMPLEMENT("9K(FAST)"),.INIT_FILE("NONE"),.FILL_ALL("NONE")) u_timestamps(
    .dia(timestamp_word),.addra(index_count[6:0]),.cea(timestamp_write),
    .ocea(1'b0),.clka(clk),.wea(1'b1),.rsta(1'b0),.bea(1'b0),.doa(),
    .dib(32'd0),.addrb(scan_count[6:0]),.ceb(timestamp_fetch),.oceb(1'b1),
    .clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),.dob(timestamp_read));
always @(posedge clk or posedge rst) begin
    if(rst) begin scan_valid<=0;scan_address_d<=0;end
    else begin scan_valid<=timestamp_fetch;scan_address_d<=scan_count;end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE;sec_req<=0;sec_addr<=0;configured<=0;current_line<=LINE_NONE;
        base_sector<=0;count<=0;offset<=0;header_bad<=0;
        byte_count<=0;index_count<=0;scan_count<=0;
        scan_line<=LINE_NONE;assembled<=0;previous_timestamp<=0;timer<=0;
        scan_frame<=0;data_sector<=0;index_invalid<=0;smooth_format<=0;
    end else begin
        case(state)
        IDLE: begin
            sec_req<=0;
            if(file_valid) begin
                base_sector<=file_start_sector;sec_addr<=file_start_sector;sec_req<=1;
                byte_count<=0;header_bad<=0;smooth_format<=0;count<=0;offset<=0;state<=HEADER;
            end
        end
        HEADER: begin
            if(sec_data_valid) begin
                byte_count<=byte_count+1'b1;
                case(byte_count)
                0,1,2,3,4,5,6,7: begin
                    header_bad<=header_bad || !magic_byte_valid;
                    if(byte_count==7) smooth_format<=sec_data=="2";
                end
                8: count<=sec_data;
                9,10,11,14,15,21,22,23,25,26,27,32,34,35,41,42,43:
                    header_bad<=header_bad || sec_data!=0;
                12: header_bad<=header_bad || sec_data!=8'h80; // 48000=0x0000BB80
                13: header_bad<=header_bad || sec_data!=8'hBB;
                20: header_bad<=header_bad || sec_data!=(smooth_format ? 32 : 16);
                24: header_bad<=header_bad || (smooth_format ? sec_data!=128 :
                    (sec_data==0 || sec_data>32));
                33: header_bad<=header_bad || sec_data!=(smooth_format ? 8'h2C : 8'h04);
                36,37,38,39: offset<={sec_data,offset[31:8]};
                40: header_bad<=header_bad || sec_data!=(smooth_format ? 22 : 2);
                default: ;
                endcase
            end
            if(sec_end) begin sec_req<=0;state<=VALIDATE;end
        end
        VALIDATE: begin
            if(!header_valid) state<=ERROR;
            else begin
                sec_addr<=base_sector;sec_req<=1;byte_count<=0;
                index_count<=0;index_invalid<=0;assembled<=0;previous_timestamp<=0;
                data_sector<=base_sector+(offset>>9);state<=INDEX;
            end
        end
        INDEX: begin
            sec_req<=1;
            if(sec_data_valid) begin
                byte_count<=byte_count+1'b1;
                if(byte_count>=64 && index_count<count) begin
                    assembled<=timestamp_word;
                    if(byte_count[1:0]==3) begin
                        if(index_count!=0 && timestamp_word<previous_timestamp) index_invalid<=1;
                        previous_timestamp<=timestamp_word;index_count<=index_count+1'b1;
                    end
                end
            end
            if(sec_end) begin
                sec_req<=0;
                if(index_invalid) state<=ERROR;
                else if(index_count>=count) begin configured<=1;timer<=CHECK_DIV;state<=WAIT;end
                else sec_addr<=sec_addr+1'b1;
            end
        end
        WAIT: begin
            sec_req<=0;
            if(timer>=CHECK_DIV) begin
                timer<=0;scan_count<=0;scan_line<=LINE_NONE;scan_frame<=play_frame;state<=SCAN;
            end else timer<=timer+1'b1;
        end
        SCAN: begin
            if(scan_count<count) scan_count<=scan_count+1'b1;
            if(scan_valid && scan_frame>=timestamp_read) scan_line<=scan_address_d;
            // 最后一次RAM读取和比较完成后，统一发布当前行，避免漏掉末句。
            if(scan_count==count && !scan_valid) begin current_line<=scan_line;state<=WAIT;end
        end
        ERROR: begin sec_req<=0;configured<=0;current_line<=LINE_NONE;end
        default: state<=ERROR;
        endcase
        if(reload || !file_valid) begin
            state<=IDLE;configured<=0;sec_req<=0;current_line<=LINE_NONE;
            timer<=0;byte_count<=0;
        end
    end
end
endmodule
