`timescale 1ns/1ps

module riscv_ui_mmio (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid,
    input  wire [3:0]  wstrb,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg         ready,
    output reg  [31:0] rdata,
    input  wire [3:0]  key_events,
    input  wire [5:0]  img_found,
    input  wire [4:0]  img_cur,
    input  wire [31:0] audio_frame,
    input  wire [95:0] audio_levels,
    input  wire [7:0]  lyric_line,
    input  wire [7:0]  sd_err_code,
    input  wire        sd_auto_en,
    input  wire        ui_file_valid,
    input  wire        ui_scan_done,
    input  wire [31:0] ui_file_sector,
    input  wire [31:0] ui_file_bytes,
    output wire        cpu_enable,
    output wire        menu_active,
    output wire        color_frame_ready,
    output wire        color_frame_bank,
    output wire        auto_trigger,
    output wire [2:0]  menu_item,
    output wire        set_flip,
    output wire        en_subtitle,
    output wire        en_fx,
    output wire        en_osd,
    output wire [7:0]  bright_level,
    output wire [7:0]  contrast_level,
    output reg  [31:0] diag_word,
    output reg  [10:0] audio_settings,
    output reg  [1:0] photo_requests,
    output reg  [4:0] overlay_control,
    output reg  [6:0] photo_settings
);

localparam [31:0] UI_BASE = 32'h0300_0000;
localparam [31:0] UI_ID   = 32'h5549_3100;

reg [3:0]  pending_events;
reg [11:0] control_reg;
reg [15:0] level_reg;

wire selected = valid && (addr[31:8] == UI_BASE[31:8]);
wire access = selected && !ready;
wire write_access = access && (|wstrb);
wire clear_events = write_access && (addr[7:0] == 8'h04);

assign cpu_enable    = control_reg[0];
assign menu_active   = control_reg[1];
assign color_frame_ready = control_reg[9];
assign color_frame_bank = control_reg[10];
assign auto_trigger = control_reg[11];
assign menu_item     = control_reg[4:2];
assign set_flip      = control_reg[5];
assign en_subtitle   = control_reg[6];
assign en_fx         = control_reg[7];
assign en_osd        = control_reg[8];
assign bright_level  = level_reg[7:0];
assign contrast_level = level_reg[15:8];

always @(posedge clk or posedge rst) begin
    if (rst) begin
        ready          <= 1'b0;
        pending_events <= 4'd0;
        control_reg    <= 12'b0000_1100_0000;
        level_reg      <= 16'h80ff;
        diag_word      <= 32'd0;
        audio_settings <= 11'h128;
        overlay_control <= 5'd0;
        photo_requests <= 2'd0;
        photo_settings <= 7'd1;
    end else begin
        ready <= selected && !ready;
        // 清除已处理事件的同拍，新到达的按键必须保留。
        pending_events <= (pending_events &
                          ~(clear_events ? wdata[3:0] : 4'd0)) | key_events;
        if (write_access && (addr[7:0] == 8'h0c) && wstrb[0])
            control_reg <= wdata[11:0];
        if (write_access && (addr[7:0] == 8'h3c) && wstrb[0])
            overlay_control <= wdata[4:0];
        if (write_access && (addr[7:0] == 8'h40) && (&wstrb[1:0]))
            audio_settings <= wdata[10:0];
        if (write_access && (addr[7:0] == 8'h44) && wstrb[0])
            photo_requests <= photo_requests ^ wdata[1:0];
        if (write_access && (addr[7:0] == 8'h48) && wstrb[0])
            photo_settings <= {~photo_settings[6],wdata[5:0]};
        if (write_access && (addr[7:0] == 8'h10)) begin
            if (wstrb[0]) level_reg[7:0]  <= wdata[7:0];
            if (wstrb[1]) level_reg[15:8] <= wdata[15:8];
        end
        if (write_access && (addr[7:0] == 8'h2c)) begin
            if (wstrb[0]) diag_word[7:0]   <= wdata[7:0];
            if (wstrb[1]) diag_word[15:8]  <= wdata[15:8];
            if (wstrb[2]) diag_word[23:16] <= wdata[23:16];
            if (wstrb[3]) diag_word[31:24] <= wdata[31:24];
        end
    end
end

always @(*) begin
    case (addr[7:0])
        8'h00: rdata = UI_ID;
        8'h04: rdata = {28'd0, pending_events};
        8'h08: rdata = {16'd0, 5'd0, img_found, img_cur};
        8'h0c: rdata = {20'd0, control_reg};
        8'h10: rdata = {16'd0, level_reg};
        8'h14: rdata = audio_frame;
        8'h18: rdata = {24'd0, lyric_line};
        8'h1c: rdata = {23'd0, sd_auto_en, sd_err_code};
        8'h20: rdata = {30'd0, ui_scan_done, ui_file_valid};
        8'h24: rdata = ui_file_sector;
        8'h28: rdata = ui_file_bytes;
        8'h2c: rdata = diag_word;
        8'h30: rdata = audio_levels[31:0];
        8'h34: rdata = audio_levels[63:32];
        8'h38: rdata = audio_levels[95:64];
        8'h3c: rdata = 32'h4f534500 | {27'd0, overlay_control};
        8'h40: rdata = {21'd0, audio_settings};
        8'h44: rdata = 32'h50484f31;
        8'h48: rdata = {25'd0,photo_settings};
        default: rdata = 32'd0;
    endcase
end

endmodule
