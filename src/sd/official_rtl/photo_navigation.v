`timescale 1ns/1ps
// 累计用户期望的图号；目标稳定后再交给扇区/缓存流水线。
module photo_navigation (
    input wire clk,rst,
    input wire [1:0] requests,
    input wire next_pulse,
    input wire [5:0] count,
    input wire [4:0] current,
    input wire display_valid,bad_valid,
    input wire [4:0] bad_image,
    output reg [4:0] target,
    output reg pending,
    output reg dispatch
);
localparam integer PIPELINE_CYCLES=5;
reg [1:0] request_sync1,request_sync2,request_seen;
reg [2:0] settle;
wire [1:0] edges=request_sync2 ^ request_seen;
wire forward=edges[0] | next_pulse;
wire backward=edges[1];
wire move=forward ^ backward;
wire [4:0] base=pending ? target : current;

// 回绕只需比较末图，避免“加一后再做六位大小比较”的串联路径。
// count=32 时保留低5位再相减，仍得到末图31。
wire [4:0] last=count[4:0]-5'd1;
function [4:0] step;
    input [4:0] index;
    input backwards;
    input [4:0] last_index;
    begin
        if(backwards) step=index==0 ? last_index : index-5'd1;
        else step=index==last_index ? 5'd0 : index+5'd1;
    end
endfunction
wire [4:0] candidate=step(base,backward,last);
wire [4:0] skipped=step(candidate,backward,last);
wire [4:0] destination=(bad_valid && candidate==bad_image) ?
                        skipped : candidate;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        request_sync1<=0;request_sync2<=0;request_seen<=0;
        target<=0;pending<=0;dispatch<=0;settle<=0;
    end else begin
        request_sync1<=requests;request_sync2<=request_sync1;
        request_seen<=request_sync2;
        dispatch<=0;
        if(move && display_valid && count>1) begin
            target<=destination;
            pending<=1;
            settle<=PIPELINE_CYCLES;
        end else if(settle!=0) begin
            settle<=settle-1'b1;
            if(settle==1) dispatch<=1;
        end else if(display_valid && current==target) pending<=0;
        if(!pending && !move) target<=current;
    end
end
endmodule
