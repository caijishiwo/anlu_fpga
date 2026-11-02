// ---------------------------------------------------------------------------
// 图片表容量：想改"最多支持几张图"就改这三个值
//   16 张 -> CNT_BITS=5, IDX_BITS=4；  32 张 -> CNT_BITS=6, IDX_BITS=5
//   同时把 SCAN_TARGET_COUNT 改成同一个数
// ---------------------------------------------------------------------------
localparam integer MAX_IMAGES = 32;
localparam integer CNT_BITS   = 6;
localparam integer IDX_BITS   = 5;
localparam integer NBANKS     = 4;      // 显示缓存 bank 数，与 top.v 的 BANK0..3 对应

wire key_next_press;
wire key_auto_press;

wire             bmp_sec_read;          // request from bmp_read
wire [31:0]      bmp_sec_read_addr;
wire             bmp_sec_read_data_valid;
wire             bmp_sec_read_end;
wire             aud_sec_req;           // request from audio stream
wire [31:0]      aud_sec_addr;
wire             aud_sec_data_valid;
wire             aud_sec_end;
wire             aud_wr_en_w;
wire [31:0]      aud_wr_data_w;
wire             audio_found;
wire [31:0]      audio_start_sector;
wire [31:0]      audio_frames;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [5:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              scan_valid;             // 扫描结果可用（首次 scan_done 后保持）
reg              first_image_committed;
reg              preload_done;
reg              auto_play_en;
reg [1:0] manual_sync;
always @(posedge clk or posedge rst) begin
    if(rst) manual_sync<=0;
    else manual_sync<={manual_sync[0],manual_mode};
end
reg [31:0]       auto_cnt;
// 图片起始扇区表（只使用 0 .. img_found_count-1 这几项，不需要复位）
reg [31:0] sector_tbl_next [0:MAX_IMAGES-1] /* fehdl force_ram=1, ram_style="dram" */;
reg [31:0] sector_tbl_chain [0:MAX_IMAGES-1] /* fehdl force_ram=1, ram_style="bram" */;
reg [31:0] first_sector;
reg [CNT_BITS-1:0]  img_found_count;     // 扫描到的图片数（0..MAX_IMAGES）
reg [IDX_BITS-1:0]  bad_img;             // 最近一次加载失败的图（“下一张”会跳过它）
reg                 bad_img_valid;
reg [IDX_BITS-1:0]  cur_img;             // 当前正在显示的图号
reg [IDX_BITS-1:0]  load_img;            // 当前正在加载的图号

reg                 next_req_pending;
reg [IDX_BITS-1:0]  next_req_img;        // 待处理请求要切到哪张图
reg [31:0]          next_req_sec;        // 待处理请求那张图的起始扇区（提前算好，避免进组合路径）
reg                 load_busy;
reg [31:0]          load_timeout_cnt;

reg              load_abort;

// 本次 load 是否由按键/自动播放发起：成功时要把画面切到它写入的 bank
reg              manual_load;
// 每个 bank 里装的是第几张图；bank_valid[i]=1 表示 bank i 内容有效
reg [3:0]        bank_valid;
reg [IDX_BITS-1:0] bank_img [0:NBANKS-1];
// 是否出现过加载失败（调试灯用）
reg              load_failed;
// 异常码（sticky：下次加载成功后清 0）。只上报，不改变控制行为。
localparam [7:0]  ERR_NONE      = 8'h00;
localparam [7:0]  ERR_TIMEOUT   = 8'h42;   // 加载超时（会自动重试）
localparam [7:0]  ERR_LOAD_FAIL = 8'h41;   // 重试 3 次仍失败，已跳图
localparam [7:0]  ERR_NO_IMAGE  = 8'h43;   // 扫描结束却一张图都没有
reg [7:0]        err_code_r;

// 加载失败自动重试：偶发读卡失败时同一张图重读，不立刻判“坏图”而漏掉
reg [1:0]          retry_cnt;
reg                retry_pending;
reg                retry_manual;
reg [IDX_BITS-1:0] retry_img;
reg [31:0]         retry_sec;

reg [3:0] key_cnt;
always @(posedge clk or posedge rst) begin
    if (rst)
        key_cnt <= 4'd0;
    else if (key_next_press)
        key_cnt <= key_cnt + 4'd1;
end

assign dbg_info      = { img_found_count[5:0], scan_valid, load_failed, preload_done, cur_img, key_cnt };
assign err_code      = err_code_r;
assign ui_scan_done  = scan_valid;
assign auto_en       = auto_play_en;
assign dbg_key_pulse = key_next_press;

reg              source_done_seen;
// 本次 load 期间 bmp_read 是否离开过 IDLE（load 起始那一拍 bmp_ready 仍为 1，不能当“读完”）
reg              source_seen_busy;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
wire [IDX_BITS-1:0] next_from_current;   // “下一张”目标（跳过坏图）
wire [IDX_BITS-1:0] next_idx_raw;        // 纯“下一张”
wire                next_idx_is_bad;     // 这个目标正好是上次失败的图
wire [1:0]          disp_avoid;          // 写入时要避开的显示 bank（还没画面时不用避开）

// ---------------------------------------------------------------------------
// 预计算流水线（两级）：
// 100MHz 域里不能把“加法比较 + 16 选 1 扇区查表”放进状态机同一拍，
// 所以提前 2 拍把“下一张图号 / 扇区 / 命中 bank / 预加载目标”算好并存成寄存器。
// ---------------------------------------------------------------------------
reg [IDX_BITS-1:0]  nxt_raw_a;              // 级1：纯“下一张”
reg [IDX_BITS-1:0]  nxt_img_a, nxt_img_b;   // 级2/级3：跳过坏图后的目标图
reg                 chain_ok_a, chain_ok_b; // 预加载链能否继续
reg [IDX_BITS-1:0]  chain_img_a, chain_img_b;
reg [31:0]          chain_sec_b;
reg [31:0]          nxt_sec_b;
always @(posedge clk) begin
    if (scan_found_valid && img_found_count < MAX_IMAGES) begin
        sector_tbl_next[img_found_count[IDX_BITS-1:0]] <= scan_found_sector;
        sector_tbl_chain[img_found_count[IDX_BITS-1:0]] <= scan_found_sector;
    end
    nxt_sec_b <= sector_tbl_next[nxt_img_a];
    chain_sec_b <= sector_tbl_chain[chain_img_a];
end
reg                 nxt_hit_b;
reg [1:0]           nxt_bank_b;

wire [IDX_BITS-1:0] chain_next = load_img + 1'b1;
wire                chain_more = (!preload_done) &&
                                 (({1'b0, load_img} + 1'b1) < {1'b0, img_found_count}) &&
                                 (({1'b0, load_img} + 1'b1) < NBANKS);

assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};

// 目标正好是上次读失败的那张图时，再往后跳一张（单跳，组合路径短）
assign next_idx_raw    = nav_pending ? nav_target : next_index(cur_img, img_found_count);
assign next_idx_is_bad = bad_img_valid && (next_idx_raw == bad_img);
assign next_from_current = next_idx_is_bad ? next_index(next_idx_raw, img_found_count) : next_idx_raw;
assign disp_avoid = display_valid ? disp_buf_idx : 2'd3;

// 视频端在读的 bank 同步到 sd_clk 域（跨时钟，打两拍）
reg [1:0] act_buf_s1, act_buf_s2;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        act_buf_s1 <= 2'd0;
        act_buf_s2 <= 2'd0;
    end else begin
        act_buf_s1 <= active_buf_idx;
        act_buf_s2 <= act_buf_s1;
    end
end

assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign state_code = state_code_i;
assign dbg_status = {load_failed, scan_valid, load_busy, display_valid};

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);


reg [6:0] photo_sync0,photo_sync1;
reg photo_seen;
reg [4:0] photo_seconds,photo_elapsed;
wire photo_update=photo_sync1[6]!=photo_seen;
wire auto_second=auto_cnt==(CLK_FREQ_HZ-1);
wire auto_counting=!manual_sync[1] && scan_valid && auto_play_en && display_valid &&
                   !load_busy && first_image_committed && img_found_count>1;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        photo_sync0<=7'd1;photo_sync1<=7'd1;photo_seen<=0;
        photo_seconds<=5'd1;photo_elapsed<=0;
    end else begin
        photo_sync0<=photo_settings;photo_sync1<=photo_sync0;
        if(photo_update) begin
            photo_seen<=photo_sync1[6];photo_seconds<=photo_sync1[4:0];photo_elapsed<=0;
        end else if(!auto_counting) photo_elapsed<=0;
        else if(auto_second) photo_elapsed<=auto_tick ? 5'd0 : photo_elapsed+5'd1;
    end
end


assign auto_tick = auto_second && (photo_elapsed==photo_seconds-5'd1);
