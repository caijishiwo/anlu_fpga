            // 先确认 bmp_read 真的离开过 IDLE（否则 load 起始那一拍会被误判成“源已读完”）
            if (load_busy && !bmp_ready)
                source_seen_busy <= 1'b1;

            // 记住 bmp_read 已经把源图读完（离开 IDLE 后又回到 IDLE）
            // 写帧等待的计时清零统一在下方处理，避免被同拍自增覆盖。
            if (load_busy && source_seen_busy && bmp_ready && !source_done_seen) begin
                source_done_seen <= 1'b1;
            end

            // 记住写帧完成脉冲，避免“先写完后源结束”导致脉冲丢失而卡死
            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            // 只有“源图送完 + 整帧写完”都满足，才提交新图
            if (load_busy && source_done_seen && write_done_seen) begin
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                source_done_seen      <= 1'b0;
                source_seen_busy      <= 1'b0;
                write_done_seen       <= 1'b0;
                bank_valid[write_buf_idx] <= 1'b1;   // 这块 bank 内容有效
                bank_img[write_buf_idx]   <= load_img;
                if (bad_img_valid && (load_img == bad_img))
                    bad_img_valid <= 1'b0;           // 重试成功则撤销“坏图”标记
                // 首图提交，或“按键发起的加载”完成时提交：
                // 这样即使预加载还没做完，按键也能真正切换画面
                // 挂起的按键/轮播请求正好就是刚装好的这张图 → 直接显示（预取升级为切换，不再二次读卡）
                if (!display_valid || (nav_pending && load_img == nav_target)) begin
                    display_valid         <= 1'b1;
                    disp_buf_idx          <= write_buf_idx;
                    cur_img               <= load_img;
                end
                first_image_committed <= 1'b1;
                retry_cnt             <= 2'd0;   // 本次加载成功，重试计数清零
                err_code_r            <= ERR_NONE;
                manual_load           <= 1'b0;
                // 按键请求优先；否则继续把前 NBANKS 张图预加载到各自 bank
                if (next_req_pending && (img_found_count > 1'b1) && (next_req_img != load_img) && next_req_img == nav_target) begin
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
                end else if (chain_ok_b && !preload_done) begin
                    load_img         <= chain_img_b;
                    load_sector      <= chain_sec_b;
                    write_buf_idx    <= wr_bank_sel;
                    bank_valid[wr_bank_sel] <= 1'b0;   // 开写即失效：避免切到半写坏的 bank
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    manual_load      <= 1'b0;
                    source_done_seen <= 1'b0;
                    source_seen_busy <= 1'b0;
                    write_done_seen  <= 1'b0;
                end else begin
                    next_req_pending <= 1'b0;   // 请求的就是刚提交的这张图：已显示，消费掉
                    preload_done     <= 1'b1;
                end
            end else if (load_busy) begin
                // 源结束时开始独立的写帧等待；读图阶段只累计连续无进展时间。
                // 大图可跨越多个2秒窗口，仍须在停止读图/输出后明确报错。
                if ((source_seen_busy && bmp_ready && !source_done_seen) ||
                    (!source_done_seen && (bmp_sec_read_data_valid || bmp_data_wr_en))) begin
                    load_timeout_cnt <= 32'd0;
                end else if (load_timeout_cnt > (source_done_seen ? TIMEOUT_WRITE : TIMEOUT_LOAD)) begin
                    // 超时（偶发读卡失败/文件截断）：先同一张图自动重试，连续 3 次失败才判坏图跳过
                    load_busy             <= 1'b0;
                    load_timeout_cnt      <= 32'd0;
                    source_done_seen      <= 1'b0;
                    source_seen_busy      <= 1'b0;
                    write_done_seen       <= 1'b0;
                    load_abort            <= 1'b1;      // 先让 bmp_read 回 IDLE
                    load_failed           <= 1'b1;
                    // 还能重试 → 超时码；重试已耗尽 → 坏图码
                    err_code_r            <= (retry_cnt < 2'd2) ? ERR_TIMEOUT : ERR_LOAD_FAIL;
                    if (retry_cnt < 2'd2) begin
                        // 偶发读卡失败（卡顿/超时/数据少一段）：同一张图重读，最多 3 次
                        retry_cnt     <= retry_cnt + 2'd1;
                        retry_pending <= 1'b1;
                        retry_manual  <= manual_load;  // 按键/轮播发起的，重试成功后直接切过去
                        retry_img     <= load_img;
                        retry_sec     <= load_sector;
                        manual_load   <= 1'b0;
                    end else begin
                        // 连续 3 次都失败：这份文件确实有问题，本轮先跳过（下一轮还会再试）
                        retry_cnt     <= 2'd0;
                        retry_pending <= 1'b0;
                        manual_load   <= 1'b0;
                        bad_img       <= load_img;
                        bad_img_valid <= 1'b1;
                        preload_done  <= 1'b1;
                    end
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

