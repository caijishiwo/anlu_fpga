// FAT32 PICTURE 枚举：只接受有效 BMP；文件连续性在写卡验收时校验。
module picture_directory (
    input wire clk, rst, start, present,
    input wire [31:0] first_cluster, data_base, fat_base,
    input wire [3:0] cluster_shift,
    input wire [5:0] target_count,
    input wire [7:0] data,
    input wire valid, ending, header_ok,
    input wire [31:0] header_bytes,
    output reg request, done, found,
    output reg [31:0] address, found_sector,
    output reg [3:0] error
);
localparam IDLE=0, DIRECTORY=1, PROBE=2, FAT=3, NEXT=4, FINISH=5;
localparam START_OFFSET=6, START_ADDRESS=7;
localparam [31:0] END_CLUSTER=32'h0ffffff8, BAD_CLUSTER=32'h0ffffff7;
localparam [31:0] MAX_BYTES=32'd4194304;
reg [2:0] state;
reg [9:0] offset;
reg [27:0] directory_cluster;
reg [31:0] directory_sector, candidate_sector;
reg [31:0] start_offset;
reg [27:0] entry_cluster, fat_value;
reg [22:0] entry_size, candidate_bytes;
reg entry_size_overflow;
reg [7:0] first, attributes, sector_index;
reg [23:0] extension;
reg [4:0] resume_entry;
reg picked, end_directory;
reg [5:0] count;
wire [31:0] cluster_sectors=32'd1<<cluster_shift;
wire [31:0] entry_sector=data_base+((entry_cluster-28'd2)<<cluster_shift);
wire [31:0] next_directory_sector=data_base+((fat_value-28'd2)<<cluster_shift);
wire entry_live=first!=8'h00 && first!=8'he5 && attributes!=8'h0f &&
    !attributes[4] && !attributes[3] && entry_cluster>=2;
wire bmp_entry=entry_live && !entry_size_overflow &&
    extension==24'h424d50 && entry_size>=54 &&
    entry_size<=MAX_BYTES && data==0;
wire [8:0] fat_offset={directory_cluster[6:0],2'b00};
always @(posedge clk or posedge rst) begin
    if(rst) offset<=0;
    else if(ending || state==IDLE) offset<=0;
    else if(valid) offset<=offset+1'b1;
end
// 目录字段在最后一个字节前就绪，文件大小高字节直接检查当前输入。
always @(posedge clk) begin
    if(state==DIRECTORY && valid) begin
        case(offset[4:0])
            0:first<=data;
            8:extension[23:16]<=data;
            9:extension[15:8]<=data;
            10:extension[7:0]<=data;
            11:attributes<=data;
            20:entry_cluster[23:16]<=data;
            21:entry_cluster[27:24]<=data[3:0];
            26:entry_cluster[7:0]<=data;
            27:entry_cluster[15:8]<=data;
            28:entry_size[7:0]<=data;
            29:entry_size[15:8]<=data;
            30:begin entry_size[22:16]<=data[6:0];entry_size_overflow<=data[7];end
            default:;
        endcase
    end
    if(state==FAT && valid && offset[8:2]==fat_offset[8:2]) begin
        case(offset[1:0])
            0:fat_value[7:0]<=data;
            1:fat_value[15:8]<=data;
            2:fat_value[23:16]<=data;
            3:fat_value[27:24]<=data[3:0];
        endcase
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE;request<=0;done<=0;found<=0;error<=0;
        address<=0;found_sector<=0;count<=0;start_offset<=0;
        picked<=0;end_directory<=0;resume_entry<=0;sector_index<=0;
    end else begin
        found<=0;
        case(state)
            IDLE: if(start) begin
                done<=0;error<=0;count<=0;resume_entry<=0;
                picked<=0;end_directory<=0;sector_index<=0;
                directory_cluster<=first_cluster[27:0];
                state<=present ? START_OFFSET : FINISH;
            end
            START_OFFSET: begin
                start_offset<=(directory_cluster-28'd2)<<cluster_shift;
                state<=START_ADDRESS;
            end
            START_ADDRESS: begin
                directory_sector<=data_base+start_offset;
                address<=data_base+start_offset;
                state<=DIRECTORY;
            end
            DIRECTORY: begin
                request<=1;
                if(valid && offset[4:0]==31 && {1'b0,offset[8:5]}>=resume_entry && !picked) begin
                    if(first==0) end_directory<=1;
                    if(!end_directory && bmp_entry) begin
                        picked<=1;
                        candidate_sector<=entry_sector;candidate_bytes<=entry_size;
                        resume_entry<={1'b0,offset[8:5]}+1'b1;
                    end
                end
                if(ending) begin
                    request<=0;
                    if(picked) begin address<=candidate_sector;state<=PROBE;end
                    else state<=NEXT;
                end
            end
            PROBE: begin
                request<=1;
                if(ending) begin
                    request<=0;
                    if(!header_ok || header_bytes!=candidate_bytes) begin
                        error<=1;state<=FINISH;
                    end else begin
                        found<=1;found_sector<=candidate_sector;count<=count+1'b1;
                        picked<=0;address<=directory_sector;state<=DIRECTORY;
                        if(count+1'b1>=target_count) state<=FINISH;
                    end
                end
            end
            FAT: begin
                request<=1;
                if(ending) begin
                    request<=0;
                    if(fat_value>=END_CLUSTER) state<=FINISH;
                    else if(fat_value<2 || fat_value==BAD_CLUSTER || fat_value==directory_cluster) begin
                        error<=3;state<=FINISH;
                    end else begin
                        directory_cluster<=fat_value;sector_index<=0;
                        directory_sector<=next_directory_sector;address<=next_directory_sector;
                        state<=DIRECTORY;
                    end
                end
            end
            NEXT: begin
                resume_entry<=0;
                if(end_directory) state<=FINISH;
                else if({24'd0,sector_index}+1<cluster_sectors) begin
                    sector_index<=sector_index+1'b1;
                    directory_sector<=directory_sector+1'b1;
                    address<=directory_sector+1'b1;state<=DIRECTORY;
                end else begin
                    address<=fat_base+(directory_cluster>>7);state<=FAT;
                end
            end
            FINISH: begin request<=0;done<=1;state<=IDLE;end
            default: state<=IDLE;
        endcase
    end
end
endmodule
