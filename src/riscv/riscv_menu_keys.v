`timescale 1ns/1ps

module riscv_menu_keys #(
    parameter integer DEBOUNCE_CYCLES = 250_000,
    parameter integer HOLD_CYCLES = 60_000_000
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       key_next,
    input  wire       key_dec,
    input  wire       key_menu,
    output reg  [3:0] events
);

localparam integer DB_BITS = (DEBOUNCE_CYCLES <= 1) ? 1 : $clog2(DEBOUNCE_CYCLES);
localparam integer HOLD_BITS = (HOLD_CYCLES <= 1) ? 1 : $clog2(HOLD_CYCLES);
reg [2:0] key_sync1, key_sync2, stable_n;
reg [DB_BITS-1:0] debounce_count [0:2];
reg [HOLD_BITS-1:0] hold_cnt;
reg menu_long;
wire next_down = !stable_n[0];
wire dec_down = !stable_n[1];
wire menu_down = !stable_n[2];
integer index;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        key_sync1 <= 3'b111;
        key_sync2 <= 3'b111;
        stable_n <= 3'b111;
        for (index=0; index<3; index=index+1) debounce_count[index] <= 0;
    end else begin
        // 复用赛项例程的两级同步和双边沿消抖方式。
        key_sync1 <= {key_menu, key_dec, key_next};
        key_sync2 <= key_sync1;
        for (index=0; index<3; index=index+1) begin
            if (key_sync2[index] == stable_n[index]) debounce_count[index] <= 0;
            else if (debounce_count[index] == DEBOUNCE_CYCLES-1) begin
                debounce_count[index] <= 0;
                stable_n[index] <= key_sync2[index];
            end else debounce_count[index] <= debounce_count[index] + 1'b1;
        end
    end
end

reg next_d, dec_d, menu_d;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        events <= 4'd0; next_d <= 0; dec_d <= 0; menu_d <= 0;
        hold_cnt <= 0; menu_long <= 0;
    end else begin
        events <= 4'd0;
        next_d <= next_down; dec_d <= dec_down; menu_d <= menu_down;
        if (next_down && !next_d) events[0] <= 1'b1;
        if (dec_down && !dec_d) events[1] <= 1'b1;
        if (!menu_down) begin
            hold_cnt <= 0;
            // 短按在松手时确认；长按已返回，松手不再触发确认。
            if (menu_d && !menu_long) events[2] <= 1'b1;
            menu_long <= 0;
        end else if (!menu_long) begin
            if (hold_cnt == HOLD_CYCLES-1) begin
                menu_long <= 1'b1;
                events[3] <= 1'b1;
            end else hold_cnt <= hold_cnt + 1'b1;
        end
    end
end

endmodule
