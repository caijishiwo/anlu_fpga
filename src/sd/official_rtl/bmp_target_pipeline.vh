always @(posedge clk or posedge rst) begin
    if (rst) begin
        nxt_img_a   <= {IDX_BITS{1'b0}};
        nxt_img_b   <= {IDX_BITS{1'b0}};
        nxt_raw_a   <= {IDX_BITS{1'b0}};
        chain_ok_a  <= 1'b0;
        chain_ok_b  <= 1'b0;
        chain_img_a <= {IDX_BITS{1'b0}};
        chain_img_b <= {IDX_BITS{1'b0}};
        nxt_hit_b   <= 1'b0;
        nxt_bank_b  <= 2'd0;
    end else begin
        // 级1：纯“下一张”（只含 加法/比较/选择）
        nxt_raw_a   <= next_idx_raw;
        // 级2：跳过上次失败的那张
        nxt_img_a   <= (!nav_pending && bad_img_valid && (nxt_raw_a == bad_img))
                       ? next_index(nxt_raw_a, img_found_count) : nxt_raw_a;
        chain_img_a <= chain_next;
        chain_ok_a  <= chain_more;
        // 级3：扇区查表 / bank 命中判断（输入都是寄存器，路径短）
        nxt_img_b   <= nxt_img_a;
        nxt_hit_b   <= bank_has(nxt_img_a);
        nxt_bank_b  <= bank_holding(nxt_img_a);
        if (load_busy && source_done_seen && write_done_seen && nxt_img_a == load_img) begin
            nxt_hit_b  <= 1'b1;
            nxt_bank_b <= write_buf_idx;
        end
        chain_img_b <= chain_img_a;
        chain_ok_b  <= chain_ok_a;
    end
end
