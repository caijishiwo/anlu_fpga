`timescale 1ns/1ps
// Stereo tone control in the 25 MHz HDMI audio sample domain.
module audio_tone_control (
    input wire clk,rst,in_valid,
    input wire signed [23:0] left_in,right_in,
    input wire [3:0] volume,
    input wire [2:0] bass,treble,
    input wire mute,
    output reg out_valid,
    output reg signed [23:0] left_out,right_out
);
reg signed [17:0] low_state_l,low_state_r,fast_state_l,fast_state_r;
reg signed [17:0] sample_l,sample_r,low_l,low_r,high_l,high_r;
reg signed [20:0] mix_l,mix_r;
reg valid_1,valid_2;
wire signed [17:0] input_l={{2{left_in[23]}},left_in[23:8]};
wire signed [17:0] input_r={{2{right_in[23]}},right_in[23:8]};

function signed [20:0] tone_delta;
input signed [17:0] component;
input [2:0] level;
begin
    case(level)
        0:tone_delta=-(component>>>1);
        1:tone_delta=-(component>>>2);
        3:tone_delta=component>>>2;
        4:tone_delta=component>>>1;
        default:tone_delta=0;
    endcase
end
endfunction

function signed [20:0] volume_scale;
input signed [20:0] value;
input [3:0] level;
begin
    case(level)
        0:volume_scale=0;
        1:volume_scale=value>>>3;
        2:volume_scale=value>>>2;
        3:volume_scale=(value>>>2)+(value>>>3);
        4:volume_scale=value>>>1;
        5:volume_scale=(value>>>1)+(value>>>3);
        6:volume_scale=(value>>>1)+(value>>>2);
        7:volume_scale=(value>>>1)+(value>>>2)+(value>>>3);
        default:volume_scale=value;
    endcase
end
endfunction

function signed [23:0] to_hdmi;
input signed [20:0] value;
reg signed [15:0] clipped;
begin
    if(value>21'sd32767) clipped=16'sh7fff;
    else if(value< -21'sd32768) clipped=16'sh8000;
    else clipped=value[15:0];
    to_hdmi={clipped,8'd0};
end
endfunction

always @(posedge clk or posedge rst) begin
    if(rst) begin
        low_state_l<=0;low_state_r<=0;fast_state_l<=0;fast_state_r<=0;
        sample_l<=0;sample_r<=0;low_l<=0;low_r<=0;high_l<=0;high_r<=0;
        mix_l<=0;mix_r<=0;left_out<=0;right_out<=0;
        valid_1<=0;valid_2<=0;out_valid<=0;
    end else begin
        valid_1<=in_valid;
        valid_2<=valid_1;
        out_valid<=valid_2;
        if(in_valid) begin
            sample_l<=input_l;sample_r<=input_r;
            low_l<=low_state_l;low_r<=low_state_r;
            high_l<=input_l-fast_state_l;high_r<=input_r-fast_state_r;
            low_state_l<=low_state_l+((input_l-low_state_l)>>>4);
            low_state_r<=low_state_r+((input_r-low_state_r)>>>4);
            fast_state_l<=fast_state_l+((input_l-fast_state_l)>>>2);
            fast_state_r<=fast_state_r+((input_r-fast_state_r)>>>2);
        end
        if(valid_1) begin
            mix_l<=sample_l+tone_delta(low_l,bass)+tone_delta(high_l,treble);
            mix_r<=sample_r+tone_delta(low_r,bass)+tone_delta(high_r,treble);
        end
        if(valid_2) begin
            left_out<=mute ? 24'sd0 : to_hdmi(volume_scale(mix_l,volume));
            right_out<=mute ? 24'sd0 : to_hdmi(volume_scale(mix_r,volume));
        end
    end
end
endmodule
