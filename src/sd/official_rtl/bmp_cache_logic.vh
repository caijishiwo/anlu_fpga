// 下一张（回卷），count = 扫描到的图片数
function [IDX_BITS-1:0] next_index;
    input [IDX_BITS-1:0] cur;
    input [CNT_BITS-1:0] count;
    begin
        if ((count == 0) || (({1'b0, cur} + 1'b1) >= count))
            next_index = {IDX_BITS{1'b0}};
        else
            next_index = cur + 1'b1;
    end
endfunction

// 目标图是否已经在某个 bank 里
function bank_has;
    input [IDX_BITS-1:0] img;
    begin
        bank_has = (bank_valid[0] && (bank_img[0] == img)) ||
                   (bank_valid[1] && (bank_img[1] == img)) ||
                   (bank_valid[2] && (bank_img[2] == img)) ||
                   (bank_valid[3] && (bank_img[3] == img));
    end
endfunction

// 目标图所在的 bank 号（调用前先用 bank_has 确认存在）
function [1:0] bank_holding;
    input [IDX_BITS-1:0] img;
    begin
        if      (bank_valid[0] && (bank_img[0] == img)) bank_holding = 2'd0;
        else if (bank_valid[1] && (bank_img[1] == img)) bank_holding = 2'd1;
        else if (bank_valid[2] && (bank_img[2] == img)) bank_holding = 2'd2;
        else                                            bank_holding = 2'd3;
    end
endfunction

// 选一块写入用的 bank：优先空 bank，其次轮转；avoid_a/avoid_b 是必须避开的 bank
//（avoid_b 用于“同一拍刚写完、bank_valid 还没更新”的那一块，否则预加载会互相覆盖）
function [1:0] free_bank2;
    input [1:0] avoid_a;
    input [1:0] avoid_b;
    reg         occ0, occ1, occ2, occ3;
    begin
        occ0 = bank_valid[0] || (avoid_a == 2'd0) || (avoid_b == 2'd0);
        occ1 = bank_valid[1] || (avoid_a == 2'd1) || (avoid_b == 2'd1);
        occ2 = bank_valid[2] || (avoid_a == 2'd2) || (avoid_b == 2'd2);
        occ3 = bank_valid[3] || (avoid_a == 2'd3) || (avoid_b == 2'd3);
        if      (!occ0) free_bank2 = 2'd0;
        else if (!occ1) free_bank2 = 2'd1;
        else if (!occ2) free_bank2 = 2'd2;
        else if (!occ3) free_bank2 = 2'd3;
        else if ((avoid_a != 2'd0) && (avoid_b != 2'd0)) free_bank2 = 2'd0;
        else if ((avoid_a != 2'd1) && (avoid_b != 2'd1)) free_bank2 = 2'd1;
        else if ((avoid_a != 2'd2) && (avoid_b != 2'd2)) free_bank2 = 2'd2;
        else                                            free_bank2 = 2'd3;
    end
endfunction

// 选写 bank：避开 3 个 bank（正在显示 / 视频正在读 / 刚写完），剩下的才是空闲的
function [1:0] free_bank3;
    input [1:0] avoid_a;
    input [1:0] avoid_b;
    input [1:0] avoid_c;
    reg         occ0, occ1, occ2, occ3;
    begin
        occ0 = bank_valid[0] || (avoid_a == 2'd0) || (avoid_b == 2'd0) || (avoid_c == 2'd0);
        occ1 = bank_valid[1] || (avoid_a == 2'd1) || (avoid_b == 2'd1) || (avoid_c == 2'd1);
        occ2 = bank_valid[2] || (avoid_a == 2'd2) || (avoid_b == 2'd2) || (avoid_c == 2'd2);
        occ3 = bank_valid[3] || (avoid_a == 2'd3) || (avoid_b == 2'd3) || (avoid_c == 2'd3);
        if      (!occ0) free_bank3 = 2'd0;
        else if (!occ1) free_bank3 = 2'd1;
        else if (!occ2) free_bank3 = 2'd2;
        else if (!occ3) free_bank3 = 2'd3;
        else if ((avoid_a != 2'd0) && (avoid_b != 2'd0) && (avoid_c != 2'd0)) free_bank3 = 2'd0;
        else if ((avoid_a != 2'd1) && (avoid_b != 2'd1) && (avoid_c != 2'd1)) free_bank3 = 2'd1;
        else if ((avoid_a != 2'd2) && (avoid_b != 2'd2) && (avoid_c != 2'd2)) free_bank3 = 2'd2;
        else                                                            free_bank3 = 2'd3;
    end
endfunction

function [1:0] free_bank;
    input [1:0] avoid;
    begin
        free_bank = free_bank2(avoid, avoid);
    end
endfunction

// ---- 命中判断：直接用本拍 bank 表展开写，避免函数/隐式线网的坑 ----
wire nxt_hit_ready = nxt_hit_b && !(load_busy && nxt_img_b == load_img);

// 写目标 bank：展开的 free_bank3 —— 避开 显示中 / 视频在读 / 刚写完，优先空 bank
wire occ0_b = bank_valid[0] || (disp_avoid == 2'd0) || (act_buf_s2 == 2'd0) || (write_buf_idx == 2'd0);
wire occ1_b = bank_valid[1] || (disp_avoid == 2'd1) || (act_buf_s2 == 2'd1) || (write_buf_idx == 2'd1);
wire occ2_b = bank_valid[2] || (disp_avoid == 2'd2) || (act_buf_s2 == 2'd2) || (write_buf_idx == 2'd2);
wire occ3_b = bank_valid[3] || (disp_avoid == 2'd3) || (act_buf_s2 == 2'd3) || (write_buf_idx == 2'd3);
wire [1:0] wr_bank_sel = (!occ0_b) ? 2'd0 : (!occ1_b) ? 2'd1 : (!occ2_b) ? 2'd2 : (!occ3_b) ? 2'd3 :
                         ((disp_avoid != 2'd0) && (act_buf_s2 != 2'd0) && (write_buf_idx != 2'd0)) ? 2'd0 :
                         ((disp_avoid != 2'd1) && (act_buf_s2 != 2'd1) && (write_buf_idx != 2'd1)) ? 2'd1 :
                         ((disp_avoid != 2'd2) && (act_buf_s2 != 2'd2) && (write_buf_idx != 2'd2)) ? 2'd2 : 2'd3;

// ---------------- 预计算流水线（两级，见上面的说明） ----------------
