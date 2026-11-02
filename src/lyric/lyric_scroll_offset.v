module lyric_scroll_offset #(
    parameter integer FRAMES_PER_STEP=4
)(
    input wire clk,rst,frame,line_changed,
    output reg [5:0] offset
);
localparam [5:0] MAX_OFFSET=6'd32;
reg [7:0] frame_count;
reg reverse;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        offset<=0;frame_count<=0;reverse<=0;
    end else if(line_changed) begin
        offset<=0;frame_count<=0;reverse<=0;
    end else if(frame) begin
        if(frame_count==FRAMES_PER_STEP-1) begin
            frame_count<=0;
            if(reverse) begin
                offset<=offset-1'b1;
                if(offset==1) reverse<=0;
            end else begin
                offset<=offset+1'b1;
                if(offset==MAX_OFFSET-1) reverse<=1;
            end
        end else frame_count<=frame_count+1'b1;
    end
end
endmodule
