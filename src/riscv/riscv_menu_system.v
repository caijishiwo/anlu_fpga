`timescale 1ns/1ps

module riscv_menu_system (
    input  wire        cpu_clk,
    input  wire        rst,
    input  wire        key_next,
    input  wire        key_dec,
    input  wire        key_menu,
    input  wire [5:0]  img_found,
    input  wire [4:0]  img_cur,
    input  wire [31:0] audio_frame,
    input  wire [95:0] audio_levels,
    input  wire [7:0]  lyric_line,
    input  wire [7:0]  sd_err_code,
    input  wire        sd_auto_en,
    input  wire        sd_clk,
    input wire music_safe,music_finished,
    output wire music_controlled,music_restart,
    output wire [31:0] music_sector,music_frames,music_lyric,
    output wire [6:0]  photo_settings,
    output wire        ui_sec_write,
    output wire [7:0]  ui_write_data,
    input wire ui_write_next,ui_write_end,ui_write_error,
    output wire        ui_sec_req,
    output wire [31:0] ui_sec_addr,
    input  wire        ui_sec_data_valid,
    input  wire [7:0]  ui_sec_data,
    input  wire        ui_sec_end,
    input  wire        ui_file_valid,
    input  wire        ui_scan_done,
    input  wire [31:0] ui_file_sector,
    input  wire [31:0] ui_file_bytes,
    input  wire        vid_clk,
    input  wire        vid_de,
    input  wire        vid_vs,
    input  wire [9:0]  vid_x,
    input  wire [9:0]  vid_y,
    input  wire        mem_clk,
    input  wire        sdr_init_done,
    input  wire        sdr_rd_en,
    input  wire [31:0] sdr_rd_dout,
    output wire        cpu_app_req,
    output wire        cpu_app_is_write,
    input  wire        cpu_app_grant,
    output wire        app_wr_en,
    output wire [20:0] app_wr_addr,
    output wire [3:0]  app_wr_dm,
    output wire [31:0] app_wr_din,
    output wire        app_rd_en,
    output wire [20:0] app_rd_addr,
    output wire        run_led,
    output wire        debug_tx,
    output wire        cpu_enable,
    output wire        menu_active,
    output wire        color_frame_ready,
    output wire        color_frame_bank,
    output wire        auto_trigger,
    output wire [1:0]  photo_requests,
    output wire        menu_visible,
    output wire [2:0]  menu_item,
    output wire        set_flip,
    output wire        en_subtitle,
    output wire        en_fx,
    output wire        en_osd,
    output wire [7:0]  bright_level,
    output wire [7:0]  contrast_level,
    output wire [31:0] diag_word,
    output wire [10:0] audio_settings,
    output wire        menu_page,
    output wire        menu_pixel,
    output wire        menu_accent,
    output wire        menu_muted,
    output wire        overlay_mode,
    output wire        player_mode,
    output wire        lyrics_view
);

wire        iomem_valid, iomem_ready;
wire        iomem_instr;
wire [3:0]  iomem_wstrb;
wire [31:0] iomem_addr, iomem_wdata, iomem_rdata;
wire        ctrl_ready, sdram_ready, sd_port_ready;
wire music_ready;
wire [31:0] music_rdata;
wire music_addr=iomem_addr[31:12]==20'h03004;
wire [31:0] ctrl_rdata, sdram_rdata, sd_port_rdata;
wire peripheral_ready;
wire [31:0] peripheral_rdata;
reg response_ready;
reg [31:0] response_data;
wire peripheral_valid=iomem_valid && !response_ready;
wire [3:0]  key_events;
wire [4:0] overlay_control;
reg [4:0] overlay_active;
reg vid_vs_d;
wire osd_addr=iomem_addr[31:14]==18'h01400;
reg osd_ready;
always @(posedge cpu_clk or posedge rst) begin
    if(rst) begin osd_ready<=0; overlay_active<=0; vid_vs_d<=0; end
    else begin
        osd_ready<=peripheral_valid && osd_addr && !osd_ready;
        vid_vs_d<=vid_vs;
        if(vid_vs && !vid_vs_d) overlay_active<=overlay_control;
    end
end
assign overlay_mode=overlay_active[0];
assign player_mode=overlay_active[1];
assign lyrics_view=overlay_active[4];
wire ctrl_addr = iomem_addr[31:8] == 24'h030000;
wire sd_port_addr = iomem_addr[31:12] == 20'h03002;
localparam [20:0] SDRAM_UI_BASE_WORD = 21'd1228800;
localparam [31:0] SDRAM_UI_CPU_BASE = 32'h04000000;
localparam [31:0] SDRAM_UI_CPU_LIMIT = 32'h04350000;
wire sdram_addr = (iomem_addr >= SDRAM_UI_CPU_BASE) &&
                  (iomem_addr < SDRAM_UI_CPU_LIMIT);
wire [20:0] sdram_word_addr = SDRAM_UI_BASE_WORD +
                              {1'b0, iomem_addr[21:2]};

riscv_soc u_soc (
    .clk(cpu_clk), .rst_all(rst), .ser_tx(debug_tx), .ser_rx(1'b1),
    .run_led(run_led), .iomem_valid(iomem_valid),
    .iomem_instr(iomem_instr),
    .iomem_wstrb(iomem_wstrb), .iomem_addr(iomem_addr),
    .iomem_wdata(iomem_wdata), .iomem_ready(iomem_ready),
    .iomem_rdata(iomem_rdata)
);

riscv_menu_keys #(
    .DEBOUNCE_CYCLES(125_000),
    .HOLD_CYCLES(15_000_000)
) u_keys (
    .clk(cpu_clk), .rst(rst), .key_next(key_next),
    .key_dec(key_dec), .key_menu(key_menu), .events(key_events)
);

riscv_ui_mmio u_mmio (
    .clk(cpu_clk), .rst(rst), .valid(peripheral_valid),
    .wstrb(iomem_wstrb), .addr(iomem_addr), .wdata(iomem_wdata),
    .ready(ctrl_ready), .rdata(ctrl_rdata), .key_events(key_events),
    .img_found(img_found), .img_cur(img_cur), .audio_frame(audio_frame),
    .audio_levels(audio_levels),
    .lyric_line(lyric_line), .sd_err_code(sd_err_code),
    .sd_auto_en(sd_auto_en),
    .ui_file_valid(ui_file_valid), .ui_scan_done(ui_scan_done),
    .ui_file_sector(ui_file_sector),
    .ui_file_bytes(ui_file_bytes), .cpu_enable(cpu_enable),
    .menu_active(menu_active),
    .color_frame_ready(color_frame_ready),
    .color_frame_bank(color_frame_bank), .auto_trigger(auto_trigger),
    .menu_item(menu_item),
    .set_flip(set_flip), .en_subtitle(en_subtitle), .en_fx(en_fx),
    .en_osd(en_osd), .bright_level(bright_level),
    .contrast_level(contrast_level), .diag_word(diag_word),
    .audio_settings(audio_settings),
    .photo_requests(photo_requests),
    .overlay_control(overlay_control),.photo_settings(photo_settings)
);

assign menu_visible = overlay_active[2];
player_osd_plane u_osd_plane (
    .clk(cpu_clk), .write_en(peripheral_valid && osd_addr && !osd_ready && (&iomem_wstrb)),
    .write_addr(iomem_addr[13:2]), .write_data(iomem_wdata),
    .enabled(overlay_active[0] && color_frame_ready),
    .menu(overlay_active[2]), .player(overlay_active[1]), .lyrics_view(overlay_active[4]),
    .selected(menu_item),
    .page(overlay_active[3]), .x(vid_x), .y(vid_y),
    .hit(menu_page), .pixel(menu_pixel), .accent(menu_accent), .muted(menu_muted)
);

riscv_ui_sd_port u_sd_port (
    .cpu_clk(cpu_clk), .sd_clk(sd_clk), .rst(rst),
    .valid(peripheral_valid && sd_port_addr),
    .wstrb(iomem_wstrb), .addr(iomem_addr), .wdata(iomem_wdata),
    .ready(sd_port_ready), .rdata(sd_port_rdata),
    .sec_req(ui_sec_req), .sec_addr(ui_sec_addr),
    .sec_data_valid(ui_sec_data_valid), .sec_data(ui_sec_data),
    .sec_write(ui_sec_write),.sec_write_data(ui_write_data),
    .sec_write_next(ui_write_next),.sec_write_end(ui_write_end),
    .sec_write_error(ui_write_error),.sec_end(ui_sec_end)
);

cpu_sdram_bridge #(.ENABLE_INSTRUCTION_CACHE(1)) u_sdram_bridge (
    .clk_cpu(cpu_clk), .rst_cpu_n(~rst), .valid(peripheral_valid && sdram_addr),
    .instr(iomem_instr),
    .wstrb(iomem_wstrb), .word_addr(sdram_word_addr),
    .wdata(iomem_wdata), .ready(sdram_ready), .rdata(sdram_rdata),
    .clk_mem(mem_clk), .rst_mem_n(~rst), .sdr_init_done(sdr_init_done),
    .app_req(cpu_app_req), .app_is_write(cpu_app_is_write),
    .app_grant(cpu_app_grant),
    .app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr),
    .app_wr_dm(app_wr_dm), .app_wr_din(app_wr_din),
    .app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr),
    .sdr_rd_en(sdr_rd_en), .sdr_rd_dout(sdr_rd_dout)
);

riscv_music_control u_music_control (
    .cpu_clk(cpu_clk),.sd_clk(sd_clk),.rst(rst),.valid(peripheral_valid && music_addr),
    .wstrb(iomem_wstrb),.addr(iomem_addr),.wdata(iomem_wdata),
    .ready(music_ready),.rdata(music_rdata),.safe_to_switch(music_safe),
    .finished(music_finished),.controlled(music_controlled),.restart(music_restart),
    .sector(music_sector),.frames(music_frames),.lyric(music_lyric)
);

assign peripheral_ready = (ctrl_addr && ctrl_ready) ||
                     (music_addr && music_ready) ||
                     (osd_addr && osd_ready) ||
                     (sd_port_addr && sd_port_ready) ||
                     (sdram_addr && sdram_ready);
assign peripheral_rdata = ctrl_addr ? ctrl_rdata :
                     music_addr ? music_rdata :
                     sd_port_addr ? sd_port_rdata :
                     sdram_addr ? sdram_rdata : 32'd0;

// 寄存外设返回，截断地址译码到CPU指令译码的组合路径。
// 应答期间暂停向外设转发valid，避免翻转命令被重复执行。
always @(posedge cpu_clk or posedge rst) begin
    if(rst) begin response_ready<=0;response_data<=0;end
    else begin
        response_ready<=0;
        if(peripheral_valid && peripheral_ready) begin
            response_ready<=1;
            response_data<=peripheral_rdata;
        end
    end
end
assign iomem_ready=response_ready;
assign iomem_rdata=response_data;

endmodule
