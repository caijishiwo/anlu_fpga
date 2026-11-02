module audio_start_gate (
    input wire clk,rst,controlled,
    input wire [23:0] left_in,right_in,
    output wire [23:0] left_out,right_out
);
reg controlled_meta,controlled_sync;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        controlled_meta<=1'b0;
        controlled_sync<=1'b0;
    end else begin
        controlled_meta<=controlled;
        controlled_sync<=controlled_meta;
    end
end
assign left_out=controlled_sync ? left_in : 24'd0;
assign right_out=controlled_sync ? right_in : 24'd0;
endmodule
