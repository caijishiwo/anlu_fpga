`timescale 1ns/1ps
// 圆环使用静态几何ROM；笔画伸缩只由真实音频时间片幅度驱动。
module record_overlay (
    input wire clk, rst, vs, enabled, disc_enabled,
    input wire [9:0] x, y,
    input wire [95:0] levels,
    output wire hit,
    output wire [23:0] rgb,
    output wire [2:0] alpha
);
localparam [9:0] CENTER_X=160, CENTER_Y=236, QUADRANT_SIZE=128;
localparam [23:0] IVORY=24'hE8E6DE, GUIDE_GRAY=24'h50514F;
localparam integer CHANNELS=12, LEVEL_BITS=8, INPUT_BITS=8;
localparam integer FRAME_BITS=CHANNELS*LEVEL_BITS;
localparam [3:0] UPDATE_CHANNELS=CHANNELS;
localparam [7:0] BASE_1=16, BASE_2=48, BASE_4=80, BASE_8=112,
    BASE_16=144, BASE_32=176, BASE_64=208, MAX_LEVEL=255, RELEASE_STEP=12;
// 分段压缩使弱音可见；真实16位样本满幅对应128。
function [7:0] display_level;
    input [7:0] magnitude;
    reg [7:0] high_fraction;
    begin
        high_fraction={2'b00,magnitude[5:0]}+{1'b0,magnitude[5:0],1'b0};
        casez(magnitude)
        8'b1???????:display_level=MAX_LEVEL;
        8'b01??????:display_level=BASE_64+{2'b00,high_fraction[7:2]};
        8'b001?????:display_level=BASE_32+{3'b000,magnitude[4:0]};
        8'b0001????:display_level=BASE_16+{3'b000,magnitude[3:0],1'b0};
        8'b00001???:display_level=BASE_8+{3'b000,magnitude[2:0],2'b00};
        8'b000001??:display_level=BASE_4+{3'b000,magnitude[1:0],3'b000};
        8'b0000001?:display_level=BASE_2+{3'b000,magnitude[0],4'b0000};
        8'b00000001:display_level=BASE_1;
        8'b00000000:display_level=0;
        default:display_level=8'bxxxxxxxx;
        endcase
    end
endfunction
function [7:0] boost_level;
    input [7:0] level;
    reg [7:0] quarter_gain,soft_room;
    begin
        quarter_gain=level>>2;
        soft_room=(MAX_LEVEL-level)>>1;
        boost_level=level+(quarter_gain<soft_room ? quarter_gain : soft_room);
    end
endfunction
function [7:0] envelope_level;
    input [7:0] current_level,target_level;
    begin
        if(target_level>=current_level) envelope_level=target_level;
        else if(current_level-target_level<=RELEASE_STEP) envelope_level=target_level;
        else envelope_level=current_level-RELEASE_STEP;
    end
endfunction
reg vs_d;
reg [FRAME_BITS-1:0] frame_levels, work_levels;
reg [CHANNELS*INPUT_BITS-1:0] input_levels;
reg [3:0] updates_left;
wire [LEVEL_BITS-1:0] target_level=
    boost_level(display_level(input_levels[INPUT_BITS-1:0]));
wire [LEVEL_BITS-1:0] next_level=
    envelope_level(work_levels[LEVEL_BITS-1:0],target_level);
wire [FRAME_BITS-1:0] next_frame={next_level,work_levels[FRAME_BITS-1:LEVEL_BITS]};
always @(posedge clk or posedge rst) begin
    if(rst) begin
        vs_d<=0; frame_levels<=0; work_levels<=0;
        input_levels<=0; updates_left<=0;
    end
    else begin
        vs_d<=vs;
        // 帧空白期锁存12路样本，每拍共用一套映射、增益和回落运算。
        if(vs && !vs_d) begin
            input_levels<=levels; work_levels<=frame_levels;
            updates_left<=UPDATE_CHANNELS;
        end
        else if(updates_left!=0) begin
            input_levels<={{INPUT_BITS{1'b0}},input_levels[CHANNELS*INPUT_BITS-1:INPUT_BITS]};
            work_levels<=next_frame;
            updates_left<=updates_left-1'b1;
            // 12路全部完成后同时提交；画面期间只读完整的一帧幅度。
            if(updates_left==1) frame_levels<=next_frame;
        end
    end
end
wire left=x<CENTER_X, above=y<CENTER_Y;
wire [9:0] dx=left ? CENTER_X-x : x-CENTER_X;
wire [9:0] dy=above ? CENTER_Y-y : y-CENTER_Y;
wire [8:0] descriptor;
ring_geometry_rom u_geometry(.clk(clk), .address({dy[6:0],dx[6:0]}),
                              .descriptor(descriptor));
reg valid_d, left_d, above_d;
always @(posedge clk) begin
    valid_d<=enabled && disc_enabled && dx<QUADRANT_SIZE && dy<QUADRANT_SIZE;
    left_d<=left; above_d<=above;
end
wire [3:0] group_index=above_d ? (left_d ? 4'd6+descriptor[5:4] :
    4'd11-descriptor[5:4]) : (left_d ? 4'd5-descriptor[5:4] :
    {2'b00,descriptor[5:4]});
wire [7:0] amplitude=frame_levels[group_index*LEVEL_BITS+:LEVEL_BITS];
wire guide=descriptor[5:4]==2'b11;
wire stroke=amplitude!=0 && amplitude[7:4]>=descriptor[3:0];
wire at_tip=amplitude[7:4]==descriptor[3:0];
wire [2:0] tip_alpha=amplitude[3:1];
wire [2:0] stroke_alpha=at_tip && tip_alpha<descriptor[8:6] ?
                        tip_alpha : descriptor[8:6];
assign hit=valid_d && descriptor[8:6]!=0 && (guide || (stroke && stroke_alpha!=0));
assign alpha=guide ? descriptor[8:6] : stroke_alpha;
assign rgb=guide ? GUIDE_GRAY : IVORY;
endmodule
