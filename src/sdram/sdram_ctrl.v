`timescale 1ns / 1ps
`include "global_def.v"

module sdram_ctrl (
    input  wire                    clk,
    input  wire                    clk_sft,
    input  wire                    rst,

    output wire                    sdr_init_done,
    output wire                    sdr_init_ref_vld,
    output wire                    sdr_busy,

    input  wire                    app_wr_en,
    input  wire [`ADDR_WIDTH-1:0]  app_wr_addr,
    input  wire [`DM_WIDTH-1:0]    app_wr_dm,
    input  wire [`DATA_WIDTH-1:0]  app_wr_din,

    input  wire                    app_rd_en,
    input  wire [`ADDR_WIDTH-1:0]  app_rd_addr,
    output wire                    sdr_rd_en,
    output wire [`DATA_WIDTH-1:0]  sdr_rd_dout
);

wire                    sdram_clk;
wire                    sdr_ras;
wire                    sdr_cas;
wire                    sdr_we;
wire [`BA_WIDTH-1:0]    sdr_ba;
wire [`ROW_WIDTH-1:0]   sdr_addr;
wire [`DM_WIDTH-1:0]    sdr_dm;
wire [`DATA_WIDTH-1:0]  sdr_dq;
// 62.5 MHz / 225°：在读数据窗口内部采样，再对齐原控制器的有效拍。
reg [`DATA_WIDTH-1:0] read_sample;
reg [`DATA_WIDTH-1:0] read_aligned;
always @(negedge clk) read_sample <= sdr_dq;
always @(posedge clk) read_aligned <= read_sample;
assign sdr_rd_dout = read_aligned;
wire controller_ref_busy;
// 刷新标志到引脚命令最多 3 拍，参考模型 tRC=70 ns 对应 125 MHz 下 9 拍。
localparam [3:0] REFRESH_DRAIN_CYCLES = 4'd12;
reg [3:0] refresh_drain;
localparam REF_IDLE=3'd0, REF_QUIET=3'd1, REF_PULSE=3'd2,
           REF_WAIT=3'd3, REF_RECOVER=3'd4;
localparam [4:0] ACCESS_DRAIN_CYCLES=5'd16;
localparam [11:0] REFRESH_TIMER_RELOAD=`SELF_REFRESH_INTERVAL-1;
reg [2:0] refresh_state;
reg [11:0] refresh_timer;
reg [3:0] quiet_cycles;

// 单拍手动刷新：先阻止新事务，再排空在途读写，保证请求既不丢失也不重复。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        refresh_state <= REF_IDLE;
        refresh_timer <= REFRESH_TIMER_RELOAD;
        quiet_cycles <= 0;
    end else if (!sdr_init_done) begin
        refresh_timer <= REFRESH_TIMER_RELOAD;
    end else begin
        if (refresh_timer!=0) refresh_timer <= refresh_timer - 1'b1;
        case (refresh_state)
            REF_IDLE: if (refresh_timer==0) begin
                refresh_state <= REF_QUIET;
                refresh_timer <= REFRESH_TIMER_RELOAD;
                quiet_cycles <= 0;
            end
            REF_QUIET: begin
                if (app_wr_en || app_rd_en) quiet_cycles <= 0;
                else if (quiet_cycles==ACCESS_DRAIN_CYCLES-1)
                    refresh_state <= REF_PULSE;
                else quiet_cycles <= quiet_cycles + 1'b1;
            end
            REF_PULSE: refresh_state <= REF_WAIT;
            REF_WAIT: if (controller_ref_busy) refresh_state <= REF_RECOVER;
            REF_RECOVER: if (!controller_ref_busy && refresh_drain==0)
                refresh_state <= REF_IDLE;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) refresh_drain <= 0;
    else if (controller_ref_busy) refresh_drain <= REFRESH_DRAIN_CYCLES;
    else if (refresh_drain!=0) refresh_drain <= refresh_drain - 1'b1;
end
assign sdr_init_ref_vld = refresh_state!=REF_IDLE || controller_ref_busy || refresh_drain!=0;

sdr_as_ram #(
    .self_refresh_open(1'b0)
) u_sdr_as_ram (
    .Sdr_clk          (clk),
    .Sdr_clk_sft      (clk_sft),
    .Rst              (rst),
    .Sdr_init_done    (sdr_init_done),
    .Sdr_init_ref_vld (controller_ref_busy),
    .Sdr_busy         (sdr_busy),
    .App_ref_req      (refresh_state==REF_PULSE),
    .App_wr_en        (app_wr_en),
    .App_wr_addr      (app_wr_addr),
    .App_wr_dm        (app_wr_dm),
    .App_wr_din       (app_wr_din),
    .App_rd_en        (app_rd_en),
    .App_rd_addr      (app_rd_addr),
    .Sdr_rd_en        (sdr_rd_en),
    .Sdr_rd_dout      (),
    .SDRAM_CLK        (sdram_clk),
    .SDR_RAS          (sdr_ras),
    .SDR_CAS          (sdr_cas),
    .SDR_WE           (sdr_we),
    .SDR_BA           (sdr_ba),
    .SDR_ADDR         (sdr_addr),
    .SDR_DM           (sdr_dm),
    .SDR_DQ           (sdr_dq)
);

SDRAM_0 u_sdram_0 (
    .clk   (sdram_clk),
    .ras_n (sdr_ras),
    .cas_n (sdr_cas),
    .we_n  (sdr_we),
    .addr  (sdr_addr[10:0]),
    .ba    (sdr_ba),
    .dq    (sdr_dq),
    .cs_n  (1'b0),
    .dm0   (sdr_dm[0]),
    .dm1   (sdr_dm[1]),
    .dm2   (sdr_dm[2]),
    .dm3   (sdr_dm[3]),
    .cke   (1'b1)
);

endmodule
