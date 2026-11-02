`timescale 1ns/1ps

module sdram_ui_arbiter (
    input  wire        clk,
    input  wire        rst,
    input  wire        video_busy,
    output wire        cpu_busy,
    input  wire        video_wr_en,
    input  wire [20:0] video_wr_addr,
    input  wire [3:0]  video_wr_dm,
    input  wire [31:0] video_wr_din,
    input  wire        video_rd_en,
    input  wire [20:0] video_rd_addr,
    output wire        video_rd_valid,
    input  wire        cpu_req,
    input  wire        cpu_is_write,
    output wire        cpu_grant,
    input  wire        cpu_wr_en,
    input  wire [20:0] cpu_wr_addr,
    input  wire [3:0]  cpu_wr_dm,
    input  wire [31:0] cpu_wr_din,
    input  wire        cpu_rd_en,
    input  wire [20:0] cpu_rd_addr,
    output wire        cpu_rd_valid,
    input  wire        sdr_rd_valid,
    output wire        app_wr_en,
    output wire [20:0] app_wr_addr,
    output wire [3:0]  app_wr_dm,
    output wire [31:0] app_wr_din,
    output wire        app_rd_en,
    output wire [20:0] app_rd_addr
);

// 原厂控制器每连续四拍才发出一个 SDRAM 命令。CPU 单字访问必须补齐。
localparam IDLE=3'd0, WRITE=3'd1, READ=3'd2, DRAIN=3'd3, RECOVER=3'd4;
// 62.5 MHz 下留出 128 ns，覆盖末组写命令、四拍数据及自动预充电。
localparam [3:0] BANK_RECOVERY_CYCLES=4'd8;
localparam [1:0] LAST_BEAT=2'd3;
reg [2:0] state;
reg [1:0] beat, returned;
reg [3:0] recovery_left;
reg [20:0] address;
reg [31:0] write_data;
reg [3:0] write_mask;
reg is_write;
reg video_idle, cpu_waiting;
reg [3:0] video_write_drain;
wire active = state != IDLE;
wire [20:0] burst_address = {address[20:2],beat};

// 请求一到就阻止新视频突发；已开始的视频突发先完整结束。
assign cpu_busy = cpu_req || active;
assign cpu_grant = cpu_req && !active && cpu_waiting && video_idle && !video_busy && video_write_drain==0;
assign app_wr_en = active ? state==WRITE : video_wr_en;
assign app_wr_addr = active ? burst_address : video_wr_addr;
assign app_wr_dm = state==WRITE ? (beat==address[1:0] ? write_mask : 4'hf) :
                   active ? 4'h0 : video_wr_dm;
assign app_wr_din = active ? write_data : video_wr_din;
assign app_rd_en = active ? state==READ : video_rd_en;
assign app_rd_addr = active ? burst_address : video_rd_addr;
assign cpu_rd_valid = active && !is_write && sdr_rd_valid && returned==address[1:0];
assign video_rd_valid = !active && sdr_rd_valid;

// 请求已阻止新视频突发一拍后，使用寄存的空闲状态授权，截断 FIFO 算术路径。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        video_idle <= 0;
        cpu_waiting <= 0;
        video_write_drain <= 0;
    end else begin
        video_idle <= !video_busy && !video_wr_en && !video_rd_en;
        cpu_waiting <= cpu_req && !active;
        // 视频 busy 结束时，末组 WRITE 命令及数据仍在控制器流水线中。
        if (video_wr_en) video_write_drain <= BANK_RECOVERY_CYCLES;
        else if (video_write_drain!=0) video_write_drain <= video_write_drain - 1'b1;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= IDLE;
        beat <= 0;
        returned <= 0;
        is_write <= 0;
        recovery_left <= 0;
    end else begin
        if (cpu_grant) begin
            is_write <= cpu_is_write;
            beat <= 0;
            returned <= 0;
            state <= cpu_is_write ? WRITE : READ;
        end
        if (state==WRITE || state==READ) begin
            beat <= beat + 1'b1;
            if (beat==LAST_BEAT) begin
                state <= state==WRITE ? RECOVER : DRAIN;
                recovery_left <= BANK_RECOVERY_CYCLES;
            end
        end
        if (state==RECOVER) begin
            if (recovery_left>1) recovery_left <= recovery_left - 1'b1;
            if (recovery_left==1 && !video_busy) state <= READ;
        end
        // 写后也读完整四拍作为完成屏障，避免下一事务抢在写管线排空前进入。
        if (active && sdr_rd_valid) begin
            returned <= returned + 1'b1;
            if (returned==LAST_BEAT) state <= IDLE;
        end
    end
end

// 载荷只在授权后的活动事务中使用，每次授权均完整覆盖，无需复位。
always @(posedge clk) begin
    if (cpu_grant) begin
        address <= cpu_is_write ? cpu_wr_addr : cpu_rd_addr;
        write_data <= cpu_wr_din;
        write_mask <= cpu_wr_dm;
    end
end

endmodule
