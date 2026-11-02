`timescale 1ns/1ps

module riscv_ui_sd_port (
    input  wire        cpu_clk,
    input  wire        sd_clk,
    input  wire        rst,
    input  wire        valid,
    input  wire [3:0]  wstrb,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg         ready,
    output wire [31:0] rdata,
    output reg         sec_req,
    output reg  [31:0] sec_addr,
    input  wire        sec_data_valid,
    input  wire [7:0]  sec_data,
    input  wire        sec_end,
    output reg         sec_write,
    output reg  [7:0]  sec_write_data,
    input  wire        sec_write_next,
    input  wire        sec_write_end,
    input  wire        sec_write_error
);

localparam [31:0] PORT_BASE = 32'h03002000;
localparam [11:0] DATA_FIRST = 12'h100;
localparam [11:0] DATA_LIMIT = 12'h300;
localparam [9:0] SECTOR_BYTES = 10'd512;

reg [31:0] sector_words [0:127];
reg [31:0] transmit_words [0:127];
reg [31:0] status_word, sector_read_word;
reg [23:0] assembling_word;
reg [31:0] request_addr;
reg request_toggle, done_toggle;
reg request_seen, cpu_error, sd_error;
reg request_sync0, request_sync1;
reg done_sync0, done_sync1;
reg [9:0] byte_count;
reg sd_active;
reg request_write;
reg [31:0] transmit_word;

wire selected = valid && (addr[31:12] == PORT_BASE[31:12]);
wire [11:0] offset = addr[11:0];
wire data_access = (offset >= DATA_FIRST) && (offset < DATA_LIMIT);
wire [7:0] word_index = offset[9:2] - 8'd64;
wire busy = request_toggle != done_sync1;
assign rdata = data_access ? sector_read_word : status_word;

// 独立同步读口及完整字写口，使扇区缓冲映射为块 RAM。
always @(posedge cpu_clk)
    if (selected && !ready && data_access)
        sector_read_word <= sector_words[word_index[6:0]];

always @(posedge cpu_clk)
    if (selected && !ready && data_access && !busy &&
        wstrb == 4'b1111 && offset[1:0] == 2'b00)
        transmit_words[word_index[6:0]] <= wdata;

// SD字节请求后的下一拍给出数据；预读口保留块RAM同步读时序。
always @(posedge sd_clk) begin
    transmit_word <= transmit_words[byte_count[8:2]];
    if (sd_active && sec_write_next)
        sec_write_data <= transmit_word >> {byte_count[1:0],3'b000};
end

always @(posedge cpu_clk or posedge rst) begin
    if (rst) begin
        ready <= 1'b0;
        status_word <= 32'd0;
        request_addr <= 32'd0;
        request_write <= 1'b0;
        request_toggle <= 1'b0;
        request_seen <= 1'b0;
        cpu_error <= 1'b0;
        done_sync0 <= 1'b0;
        done_sync1 <= 1'b0;
    end else begin
        done_sync0 <= done_toggle;
        done_sync1 <= done_sync0;
        ready <= selected && !ready;
        if (selected && !ready) begin
            if (|wstrb) begin
                if ((offset == 12'h000 || offset == 12'h008) &&
                    wstrb == 4'b1111 && !busy) begin
                    request_addr <= wdata;
                    request_write <= offset == 12'h008;
                    request_toggle <= ~request_toggle;
                    request_seen <= 1'b1;
                    cpu_error <= 1'b0;
                end else if (!(data_access && !busy &&
                             wstrb == 4'b1111 && offset[1:0] == 2'b00)) begin
                    cpu_error <= 1'b1;
                end
            end else if (offset == 12'h004) begin
                status_word <= {19'd0, byte_count, cpu_error | sd_error,
                          request_seen && !busy, busy};
            end else if (offset == 12'h00c) begin
                status_word <= 32'h53445731;
            end else begin
                status_word <= 32'd0;
            end
        end
    end
end

always @(posedge sd_clk or posedge rst) begin
    if (rst) begin
        request_sync0 <= 1'b0;
        request_sync1 <= 1'b0;
        done_toggle <= 1'b0;
        sec_req <= 1'b0;
        sec_write <= 1'b0;
        sec_addr <= 32'd0;
        byte_count <= 10'd0;
        sd_error <= 1'b0;
        sd_active <= 1'b0;
    end else begin
        request_sync0 <= request_toggle;
        request_sync1 <= request_sync0;
        if (!sd_active && request_sync1 != done_toggle) begin
            sec_addr <= request_addr;
            sec_req <= !request_write;
            sec_write <= request_write;
            byte_count <= 10'd0;
            sd_error <= 1'b0;
            sd_active <= 1'b1;
        end else if (sd_active) begin
            if ((!sec_write && sec_data_valid) || (sec_write && sec_write_next)) begin
                if (byte_count < SECTOR_BYTES)
                    byte_count <= byte_count + 10'd1;
                else
                    sd_error <= 1'b1;
            end
            if ((!sec_write && sec_end) || (sec_write && sec_write_end)) begin
                sd_error <= sd_error ||
                            (sec_write && sec_write_error) ||
                            ((byte_count + (sec_write ? sec_write_next :
                                           sec_data_valid)) != SECTOR_BYTES);
                sec_req <= 1'b0;
                sec_write <= 1'b0;
                done_toggle <= request_sync1;
                sd_active <= 1'b0;
            end
        end
    end
end

always @(posedge sd_clk) begin
    if (sd_active && !sec_write && sec_data_valid && byte_count < SECTOR_BYTES) begin
        assembling_word <= {sec_data, assembling_word[23:8]};
        if (byte_count[1:0] == 2'd3)
            sector_words[byte_count[8:2]] <= {sec_data, assembling_word};
    end
end

endmodule
