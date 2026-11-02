// ---------------------------------------------------------------------
// SD read time-sharing: image (bmp_read) and audio stream share one SD bus
//   after every sector, decide who gets the next one; audio gets 1 sector
//   then images get 3 sectors  -> audio ~25% (needs 14%), images slightly slower
// ---------------------------------------------------------------------
reg        sd_owner_aud;
reg        sd_owner_lyr;
reg        sd_owner_ui;
reg [2:0]  aud_skip;
wire sd_write_end,sd_write_error,sd_write_next;
wire ui_request = ui_sec_req || ui_sec_write;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sd_owner_aud <= 1'b0;
        sd_owner_lyr <= 1'b0;
        sd_owner_ui  <= 1'b0;
        aud_skip     <= 3'd0;
    end else if (sd_sec_read_end || sd_write_end) begin
        if (sd_owner_ui) begin
            sd_owner_ui <= 1'b0;
        end else if (sd_owner_lyr) begin
            // 请求方在sec_end之后更新地址；每扇区归还，禁止预取旧地址。
            sd_owner_lyr <= 1'b0;
            if(aud_sec_req && !music_restart) sd_owner_aud<=1'b1;
            else if(ui_request) sd_owner_ui<=1'b1;
        end else if (sd_owner_aud) begin
            sd_owner_aud <= 1'b0;
            aud_skip     <= 3'd3;
        end else if (lyr_sec_req && !music_restart) begin
            // 字幕优先级最高：每次换行只要 2 个扇区，几秒才发生一次
            sd_owner_lyr <= 1'b1;
        end else if (ui_request) begin
            sd_owner_ui <= 1'b1;
        end else if (aud_sec_req && !music_restart && ((aud_skip == 3'd0) || !bmp_sec_read)) begin
            sd_owner_aud <= 1'b1;
        end else if (aud_skip != 3'd0) begin
            aud_skip <= aud_skip - 3'd1;
        end
    end else if (!music_restart && !sd_owner_aud && !sd_owner_lyr && !sd_owner_ui) begin
        if (lyr_sec_req && !bmp_sec_read)
            sd_owner_lyr <= 1'b1;
        else if (ui_request && !bmp_sec_read)
            sd_owner_ui <= 1'b1;
        else if (aud_sec_req && !bmp_sec_read)
            sd_owner_aud <= 1'b1;
    end
end

// bmp_read ????? SD???????????????? 1:3 ??
// ????"??????"???????????? 
assign sd_sec_read = sd_owner_ui ? !ui_sec_write :
                     (sd_owner_aud || sd_owner_lyr || bmp_sec_read);
assign ui_write_next = sd_owner_ui && sd_write_next;
assign ui_write_end = sd_owner_ui && sd_write_end;
assign ui_write_error = sd_owner_ui && sd_write_error;
assign sd_sec_read_addr = sd_owner_ui ? ui_sec_addr :
                          (sd_owner_lyr ? lyr_sec_addr :
                          (sd_owner_aud ? aud_sec_addr : bmp_sec_read_addr));
wire sd_owner_idle = ~sd_owner_aud & ~sd_owner_lyr & ~sd_owner_ui;
assign bmp_sec_read_data_valid = sd_sec_read_data_valid & sd_owner_idle;
assign bmp_sec_read_end        = sd_sec_read_end        & sd_owner_idle;
assign aud_sec_data_valid      = sd_sec_read_data_valid &  sd_owner_aud;
assign aud_sec_end             = sd_sec_read_end        &  sd_owner_aud;
assign lyr_sec_data_valid      = sd_sec_read_data_valid &  sd_owner_lyr;
assign lyr_sec_end             = sd_sec_read_end        &  sd_owner_lyr;
assign lyr_sec_data            = sd_sec_read_data;
assign ui_sec_data_valid       = sd_sec_read_data_valid & sd_owner_ui;
assign ui_sec_end              = sd_sec_read_end & sd_owner_ui;
assign ui_sec_data             = sd_sec_read_data;

sd_audio_stream u_sd_audio_stream (
    .clk            (clk),
    .rst            (rst),
    .enable         (music_controlled && music_frames!=0),
    .controlled(music_controlled),.restart(music_restart),.finished(music_finished),
    .start_sector   (music_controlled ? music_sector : audio_start_sector),
    .frame_count    (music_controlled ? music_frames : audio_frames),
    .fifo_used      (aud_fifo_used),
    .sec_req        (aud_sec_req),
    .sec_addr       (aud_sec_addr),
    .sec_end        (aud_sec_end),
    .sec_data_valid (aud_sec_data_valid),
    .sec_data       (sd_sec_read_data),
    .wr_en          (aud_wr_en_w),
    .wr_data        (aud_wr_data_w),
    .dbg_sectors    (),
    .frames_played  (audio_frame_pos)
);

assign aud_wr_en   = aud_wr_en_w;
assign music_safe = !aud_sec_req && !lyr_sec_req && !sd_owner_aud && !sd_owner_lyr;
assign aud_wr_data = aud_wr_data_w;

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (sd_owner_ui && ui_sec_write),
    .sd_sec_write_addr      (ui_sec_addr),
    .sd_sec_write_data      (ui_write_data),
    .sd_sec_write_data_req  (sd_write_next),
    .sd_sec_write_error     (sd_write_error),
    .sd_sec_write_end       (sd_write_end)
);
