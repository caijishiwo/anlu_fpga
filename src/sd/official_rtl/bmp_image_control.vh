always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        first_sector          <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
            preload_done <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= {CNT_BITS{1'b0}};
        bad_img               <= {IDX_BITS{1'b0}};
        bad_img_valid         <= 1'b0;
        cur_img               <= {IDX_BITS{1'b0}};
        load_img              <= {IDX_BITS{1'b0}};
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        scan_valid            <= 1'b0;
        next_req_img          <= {IDX_BITS{1'b0}};
        next_req_sec          <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        source_seen_busy      <= 1'b0;
        write_done_seen       <= 1'b0;
        display_valid         <= 1'b0;
        manual_load           <= 1'b0;
        bank_valid            <= 4'b0000;
        bank_img[0]           <= {IDX_BITS{1'b0}};
        bank_img[1]           <= {IDX_BITS{1'b0}};
        bank_img[2]           <= {IDX_BITS{1'b0}};
        bank_img[3]           <= {IDX_BITS{1'b0}};
        load_failed           <= 1'b0;
        retry_cnt             <= 2'd0;
        retry_pending         <= 1'b0;
        retry_manual          <= 1'b0;
        retry_img             <= {IDX_BITS{1'b0}};
        retry_sec             <= 32'd0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            preload_done <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= {CNT_BITS{1'b0}};
            bad_img               <= {IDX_BITS{1'b0}};
            bad_img_valid         <= 1'b0;
            cur_img               <= {IDX_BITS{1'b0}};
            load_img              <= {IDX_BITS{1'b0}};
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            scan_valid            <= 1'b0;
            next_req_img          <= {IDX_BITS{1'b0}};
            next_req_sec          <= 32'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            load_abort            <= 1'b0;
            source_done_seen      <= 1'b0;
            source_seen_busy      <= 1'b0;
            write_done_seen       <= 1'b0;
            display_valid         <= 1'b0;
            manual_load           <= 1'b0;
            bank_valid            <= 4'b0000;
            bank_img[0]           <= {IDX_BITS{1'b0}};
            bank_img[1]           <= {IDX_BITS{1'b0}};
            bank_img[2]           <= {IDX_BITS{1'b0}};
            bank_img[3]           <= {IDX_BITS{1'b0}};
            load_failed           <= 1'b0;
        end else begin
            // 扫描阶段把每张图的起始 sector 记进表里（最多 MAX_IMAGES 张）
            if (scan_found_valid) begin
                if (img_found_count < MAX_IMAGES) begin
                    if (img_found_count == 0) first_sector <= scan_found_sector;
                    img_found_count <= img_found_count + 1'b1;
                end
            end

            // 扫描结果可用标志（bmp_read 侧 scan_done 可能在异常时被清，这里锁存一份）
            if (scan_done) begin
                scan_valid <= 1'b1;
                if (img_found_count == 6'd0) err_code_r <= ERR_NO_IMAGE;
            end

`include "bmp_load_completion.vh"
            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
            preload_done <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= {CNT_BITS{1'b0}};
                bad_img               <= {IDX_BITS{1'b0}};
                bad_img_valid         <= 1'b0;
                cur_img               <= {IDX_BITS{1'b0}};
                load_img              <= {IDX_BITS{1'b0}};
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                scan_valid            <= 1'b0;
                next_req_img          <= {IDX_BITS{1'b0}};
                next_req_sec          <= 32'd0;
                next_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                source_seen_busy      <= 1'b0;
                write_done_seen       <= 1'b0;
                manual_load           <= 1'b0;
                bank_valid            <= 4'b0000;
                bank_img[0]           <= {IDX_BITS{1'b0}};
                bank_img[1]           <= {IDX_BITS{1'b0}};
                bank_img[2]           <= {IDX_BITS{1'b0}};
                bank_img[3]           <= {IDX_BITS{1'b0}};
                load_failed           <= 1'b0;
            end else begin
                // 按键“下一张”：目标 bank 已装好就直接切；否则记一次请求，加载完成后再切
                if (nav_dispatch && (img_found_count > 1'b1)) begin
                    // 正在跑“按键加载”时要等它落地（否则会连跳两张）；预加载期间可以直接切
                    if (nxt_hit_ready) begin
                        next_req_pending <= 1'b0;
                        disp_buf_idx <= nxt_bank_b;
                        cur_img      <= nxt_img_b;
                    end else begin
                        next_req_pending <= 1'b1;
                        next_req_img     <= nxt_img_b;
                        next_req_sec     <= nxt_sec_b;
                    end
                end

                // 自动播放开/关
                if (manual_sync[1]) begin
                    auto_play_en <= 1'b0;
                    auto_cnt <= 32'd0;
                end else if (key_auto_press && scan_valid && (img_found_count > 1'b1)) begin
                    bad_img_valid <= 1'b0;   // 开新一轮：上轮失败的图再给一次机会
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                // 自动播放 1s 计数：只有当前没有写图任务时才计时
                if (!manual_sync[1] && scan_valid && auto_play_en && display_valid && !load_busy && first_image_committed && (img_found_count > 1'b1)) begin
                    if (auto_second)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // 失败重试优先：同一张图重新读一次
                if (scan_valid && bmp_ready && !load_busy && retry_pending) begin
                    load_img         <= retry_img;
                    load_sector      <= retry_sec;
                    write_buf_idx    <= wr_bank_sel;
                    bank_valid[wr_bank_sel] <= 1'b0;   // 开写即失效：避免切到半写坏的 bank
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    manual_load      <= retry_manual;
                    source_done_seen <= 1'b0;
                    source_seen_busy <= 1'b0;
                    write_done_seen  <= 1'b0;
                    retry_pending    <= 1'b0;
                end
                // 首图加载到 bank0
                else if (scan_valid && !first_image_committed && bmp_ready && !load_busy && (img_found_count != 0)) begin
                    load_img         <= {IDX_BITS{1'b0}};
                    load_sector      <= first_sector;
                    write_buf_idx    <= wr_bank_sel;
                    bank_valid[wr_bank_sel] <= 1'b0;   // 开写即失效：避免切到半写坏的 bank
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    manual_load      <= 1'b0;
                    source_done_seen <= 1'b0;
                    source_seen_busy <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 按键/自动播放的按需加载：写进一块非当前显示的 bank，成功后立即切过去
                else if (scan_valid && bmp_ready && display_valid && !load_busy && next_req_pending && next_req_img == nav_target && (img_found_count > 1'b1)) begin
                    load_img         <= next_req_img;
                    load_sector      <= next_req_sec;
                    write_buf_idx    <= wr_bank_sel;
                    bank_valid[wr_bank_sel] <= 1'b0;   // 开写即失效：避免切到半写坏的 bank
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    manual_load      <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_seen_busy <= 1'b0;
                    write_done_seen  <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end

                // 滚动预取：始终把“下一张”装进空闲 bank，轮播/按键切图都不用现读 SD，
                // 既不会漏图，也不会卡半秒（预取本身写进非显示、非在读的 bank）
                else if (scan_valid && bmp_ready && display_valid && !load_busy &&
                         (img_found_count > 1'b1) && !nxt_hit_ready) begin
                    load_img         <= nxt_img_b;
                    load_sector      <= nxt_sec_b;
                    write_buf_idx    <= wr_bank_sel;
                    bank_valid[wr_bank_sel] <= 1'b0;   // 开写即失效：避免切到半写坏的 bank
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    manual_load      <= 1'b0;
                    source_done_seen <= 1'b0;
                    source_seen_busy <= 1'b0;
                    write_done_seen  <= 1'b0;
                end


            end
        end
        if(photo_update) begin
            auto_play_en<=photo_sync1[5];auto_cnt<=32'd0;
        end
    end
end
