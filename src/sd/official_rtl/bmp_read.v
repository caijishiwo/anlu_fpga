module bmp_read(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [5:0]                scan_target_count,       // 最多记录多少张图（最多 32）
    // 连续多少个扇区没再找到新图就结束扫描（大概 512B * N；4096 = 2MB，约 0.7s）
    input  [31:0]               scan_gap_limit,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [5:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    // 目标帧像素流：由 bmp_fit_stream 整形后给出（恒为 640x480 个像素）
    output                      bmp_data_wr_en,
    output [23:0]               bmp_data
    ,
    // 串口诊断：当前扫描扇区 / 已完成的扇区读取次数
    output [31:0]               dbg_scan_sector,
    output [15:0]               dbg_read_cnt,
    output [7:0]                dbg_fs_kind,
    // 自适应缩放诊断：等比铺满后实际写入的目标帧尺寸
    output [15:0]               dbg_fit_w,
    output [15:0]               dbg_fit_h,
    // 目录法诊断：{目录起点生效, 找到 MUSIC, 找到 PICTURE, 找到音频文件}
    output [3:0]                dbg_dir_flags,
    // LYRIC.BIN（根目录里的字幕数据）第一个扇区
    output                      lyric_valid,
    output [31:0]               lyric_start_sector,
    output reg                   ui_file_valid,
    output reg [31:0]            ui_file_sector,
    output reg [31:0]            ui_file_bytes,
    // audio file on TF card (special 512B header)
    output reg                  audio_found,
    output reg [31:0]           audio_start_sector,
    output reg [31:0]           audio_frames
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;
localparam ST_DBR       = 3'd5;      // 先读一次引导扇区，算出数据区起点
localparam ST_DBR2      = 3'd6;      // 用寄存后的数据区起点启动扫描（拆时序）
localparam ST_DBR3      = 3'd7;      // 卷基址相加后再启动扫描（拆时序）

// 扫描"空转"预算：还没找到任何图时允许走很远（可能要先跨过 FAT 区）；
// 一旦找到过图，就用很小的间隔（连续 M 个扇区没新图就收工），避免空走几十 MB。
localparam [31:0] SCAN_GAP_FIRST = 32'd1048576;   // 512MB（未找到任何图时）

reg [3:0]  state;
reg picture_started;
wire picture_request, picture_done, picture_found;
wire [31:0] picture_address, picture_sector;
wire [3:0] picture_error;

localparam ST_ROOT      = 4'd8;      // dir mode: scan root dir for MUSIC folder
localparam ST_MUSIC     = 4'd9;      // dir mode: scan entries inside MUSIC folder
localparam ST_PROBE_AUD = 4'd10;     // dir mode: probe candidate file header
localparam ST_LDIR      = 4'd11;     // 在 LYRIC 目录里找与歌同名的歌词文件
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] scan_gap_active;          // 本次扫描实际使用的“连续没新图”上限
reg [15:0] read_cnt;                 // 完成的扇区读取次数
assign dbg_scan_sector = scan_sector;
assign dbg_read_cnt    = read_cnt;

always @(posedge clk or posedge rst) begin
    if (rst)
        read_cnt <= 16'd0;
    else if (sd_sec_read_end)
        read_cnt <= read_cnt + 16'd1;
end
reg        dbr_retry;                // 是否已经按 MBR 指向重读过一次
reg [31:0] fs_start_r;               // 寄存后的数据区起点
reg        fs_start_ok;              // 数据区起点是否可信
reg [31:0] vol_lba;                  // 卷（分区）起始 LBA
reg [31:0] fs_abs_r;                 // 数据区绝对扇区（= vol_lba + 卷内偏移）
reg [3:0]  dbr_probe;                // 候选分区起点探测序号

// 常见分区起始 LBA 候选（MBR 解析不出来时逐个试，通常 1~2 次就能命中）
function [31:0] probe_lba;
    input [3:0] idx;
    begin
        case (idx)
            4'd0 : probe_lba = 32'd1;
            4'd1 : probe_lba = 32'd8;
            4'd2 : probe_lba = 32'd16;
            4'd3 : probe_lba = 32'd32;
            4'd4 : probe_lba = 32'd63;
            4'd5 : probe_lba = 32'd64;
            4'd6 : probe_lba = 32'd128;
            4'd7 : probe_lba = 32'd256;
            4'd8 : probe_lba = 32'd512;
            4'd9 : probe_lba = 32'd1024;
            4'd10: probe_lba = 32'd2048;
            4'd11: probe_lba = 32'd4096;
            4'd12: probe_lba = 32'd8192;
            4'd13: probe_lba = 32'd16384;
            default: probe_lba = 32'd0;
        endcase
    end
endfunction

// 引导扇区字段
reg [7:0]  dbr_first_byte;           // DBR 第 0 字节（0xEB/0xE9 跳转指令）
reg [7:0]  dbr_bps_lo, dbr_bps_hi;   // 每扇区字节数
reg [7:0]  dbr_spc;                  // 每簇扇区数
reg [7:0]  dbr_rsv_lo, dbr_rsv_hi;   // 保留扇区数
reg [7:0]  dbr_nfat;                 // FAT 个数
reg [7:0]  dbr_spf16_lo, dbr_spf16_hi;
reg [7:0]  dbr_spf32_0, dbr_spf32_1, dbr_spf32_2, dbr_spf32_3;
reg [7:0]  exfat_sig3, exfat_sig4, exfat_sig5, exfat_sig6;  // exFAT 标记：第 3~6 字节应为 "EXFA"
reg [7:0]  exfat_spc_shift;   // exFAT: 0x6D 每簇扇区数的 2 的幂
reg [3:0]  fs_kind_r;          // 0=未知 1=FAT16/32 2=exFAT
reg [3:0]  spc_log2_r;         // 每簇扇区数 = 2^spc_log2_r
reg [7:0]  exfat_heap_0, exfat_heap_1, exfat_heap_2, exfat_heap_3;  // 簇堆起始扇区
reg [31:0] mbr_part_lba;             // MBR 第一个分区的起始 LBA
reg [7:0]  dbr_sig_lo, dbr_sig_hi;   // 0x55AA
reg [63:0] scan_magic_shift;         // sector first 8 bytes (audio magic)
reg [31:0] audio_fr;                 // audio frame count
reg [31:0] root_clu;                 // FAT32 root dir cluster
reg [31:0] root_first;               // root dir first sector
reg [31:0] music_clu;                // MUSIC folder cluster
reg        music_found;
reg [31:0] pic_clu;                  // PICTURE folder cluster
reg        pic_found;
reg [31:0] lyric_clu;                // LYRIC.BIN 文件簇号
reg        lyric_found;
reg [31:0] ldir_clu;                 // LYRIC 文件夹簇号
reg        ldir_found;
reg [63:0] audio_name;               // MUSIC 里那个音频文件的 8.3 名字
reg [31:0] ldir_first;               // LYRIC 文件夹第一个扇区
reg [31:0] dir_sector;               // current dir sector
reg [7:0]  dir_k;                    // sector index inside cluster
reg [4:0]  resume_ent;               // 5 bit: 0~16，16 = 本扇区条目已看完
reg [3:0]  file_ent;                 // hit entry index
reg [31:0] file_clu;                 // hit file first cluster
reg        file_hit;
reg [31:0] probe_sector;             // sector to probe
reg [7:0]  ent_first, ent_attr;
reg [63:0] ent_name;
reg [23:0] ent_ext;
reg [23:0] ent_size_lo;
reg [7:0]  ent_ch_lo0, ent_ch_hi0, ent_cl_lo0, ent_cl_hi0;
// 目录条目簇号寄存：4 个字节分别在 ent_byte 20/21/26/27 锁存，而消费点 ent_last
// 在 ent_byte 31，中间隔 4 拍以上，所以这里合成一拍完全安全。
// 收益：把"4 个分散字节寄存器 -> 32 位拼接"这段纯布线（实测占 60% 延迟）
// 从关键路径上摘掉，只留"寄存器 -> 减2 -> 变量移位 -> 寄存器"。
reg [31:0] ent_clu_r;
reg [31:0] ent_clu_m2_r;   // ent_clu_r - 2，再寄存一级，与变量移位各自占一拍
always @(posedge clk or posedge rst) begin
    if (rst) begin
        ent_clu_r    <= 32'd0;
        ent_clu_m2_r <= 32'd0;
    end else begin
        ent_clu_r    <= {ent_ch_hi0, ent_ch_lo0, ent_cl_hi0, ent_cl_lo0};
        ent_clu_m2_r <= ent_clu_r - 32'd2;
    end
end
reg [7:0]  dbr_root_0, dbr_root_1, dbr_root_2, dbr_root_3;
reg        dir_used;                 // diag: dir path taken
reg [31:0] scan_miss_cnt;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;

// ---- 时序优化（2026-09-22）：把 100MHz 域的深组合链改成寄存 ----
// 原路径：X_clu / file_len -> (减2 / 变量移位 / 加基址) -> sd_sec_read_addr / state，
// 100MHz 下 11 级逻辑、4 个串联 ADDER，实测 WNS -2.333ns、412 个违例端点。
// 这些量在「条目解析完成」或「头部字节锁存」时就已确定，提前一拍算好即可；
// 消费点全部在 sd_sec_read_end（相隔数百拍），不改变任何功能时序。
reg [31:0] music_first_r;       // MUSIC 目录首扇区
reg [31:0] pic_first_r;         // PICTURE 目录首扇区
reg [31:0] file_first_r;        // MUSIC 中命中文件的首扇区
reg [31:0] lyric_first_r;       // LYRIC 文件首扇区
reg [31:0] file_sector_count_r; // (file_len+511)>>9，file_len=0 时取 1
reg [31:0] hdr_file_sectors_r;  // (file_len+511)>>9
reg [31:0] audio_skip_sectors_r;// 音频文件占的扇区数 + 1
reg [31:0] root_off_r;          // (root_clu_w-2)<<spc_log2，解析 BPB 那一拍算好
reg [31:0] fs_data_start_r;     // 数据区起点寄存，避免"加+加+比较+与"串在一拍
reg        header_match_r;      // header_match 寄存（去掉 32 位比较 + 与树）
reg        hdr_is_bmp_r;        // hdr_is_bmp 寄存

wire header_match;
wire bmp_data_valid;
// 下一扫描地址：只依赖已寄存量，每拍连续算好，避免加法落进 scan_sector 的使能路径
reg [31:0] scan_next_match_r;   // scan_sector + file_sector_count_r
reg [31:0] scan_next_miss_r;    // scan_sector + 1
reg [31:0] scan_next_bmp_r;     // 扫描地址 + BMP 文件占的扇区数
reg [31:0] scan_next_audio_r;   // 扫描地址 + 音频占的扇区数
// 引导扇区里算出来的数据区起点（组合逻辑，避免在状态机里做乘法）
wire [31:0] dbr_spf         = ({dbr_spf16_hi, dbr_spf16_lo} != 16'd0)
                              ? {16'd0, dbr_spf16_hi, dbr_spf16_lo}
                              : {dbr_spf32_3, dbr_spf32_2, dbr_spf32_1, dbr_spf32_0};
wire [31:0] dbr_reserved    = {16'd0, dbr_rsv_hi, dbr_rsv_lo};
// dbr_spf 是"选 16 位还是 32 位字段"的纯组合，先寄存一级；
// dbr_data_start 因此只剩一次加法 + 一个二选一，spf+spf 用左移代替。
reg  [31:0] dbr_spf_r;
always @(posedge clk or posedge rst) begin
    if (rst) dbr_spf_r <= 32'd0;
    else     dbr_spf_r <= dbr_spf;
end
wire [31:0] dbr_data_start  = dbr_reserved +
                              ((dbr_nfat == 8'd2) ? {dbr_spf_r[30:0], 1'b0} : dbr_spf_r);
// exFAT：簇堆起始扇区在 0x58
wire [31:0] exfat_data_start = {exfat_heap_3, exfat_heap_2, exfat_heap_1, exfat_heap_0};
wire        is_exfat         = (exfat_sig3 == "E") && (exfat_sig4 == "X") &&
                               (exfat_sig5 == "F") && (exfat_sig6 == "A");   // "EXFAT" 前 4 字节

// 簇大小（扇区数）的 2 的幂：FAT 直接看 BPB[13]，exFAT 用 0x6D 的移位值
function [3:0] fat_spc_log2;
    input [7:0] spc;
    begin
        case (spc)
            8'd1   : fat_spc_log2 = 4'd0;
            8'd2   : fat_spc_log2 = 4'd1;
            8'd4   : fat_spc_log2 = 4'd2;
            8'd8   : fat_spc_log2 = 4'd3;
            8'd16  : fat_spc_log2 = 4'd4;
            8'd32  : fat_spc_log2 = 4'd5;
            8'd64  : fat_spc_log2 = 4'd6;
            8'd128 : fat_spc_log2 = 4'd7;
            default: fat_spc_log2 = 4'd6;
        endcase
    end
endfunction

// 一次“找不到”允许向前多探多少个扇区：按簇大小给（2 簇），保证能跨过上一个文件的簇对齐空洞
function [31:0] gap_from_log2;
    input [3:0] l;
    begin
        case (l)
            4'd0, 4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd6: gap_from_log2 = 32'd512;
            4'd7 : gap_from_log2 = 32'd512;   // 128 扇区/簇 → 512
            4'd8 : gap_from_log2 = 32'd1024;  // 256 扇区/簇 → 1024
            4'd9 : gap_from_log2 = 32'd2048;  // 512 扇区/簇 → 2048
            4'd10: gap_from_log2 = 32'd2048;
            default: gap_from_log2 = 32'd4096;  // 每簇 >=1MB 时放宽到 2MB 搜索窗口
        endcase
    end
endfunction

wire [31:0] gap_auto = gap_from_log2(spc_log2_r);
// 当前扇区里读到的“某个 BMP”的长度（扇区数）：非目标规格的 BMP 直接跨过去
wire [31:0] hdr_file_sectors = (file_len + 32'd511) >> 9;
wire        audio_magic_ok     = (scan_magic_shift == 64'h414E4C5557415631);  // "ANLUWAV1"

wire [4:0]  ent_byte   = rd_cnt[4:0];
wire [3:0]  ent_now    = rd_cnt[8:5];
wire        ent_last   = (ent_byte == 5'd31);
wire [31:0] ent_clu    = {ent_ch_hi0, ent_ch_lo0, ent_cl_hi0, ent_cl_lo0};
wire        ent_is_dir = ent_attr[4];
wire        ent_is_vol = ent_attr[3];
wire        ent_valid  = (ent_first != 8'hE5) && (ent_first != 8'h0F) && (ent_first != 8'h00);
wire        ent_is_file= ent_valid && !ent_is_dir && !ent_is_vol && (ent_clu >= 32'd2);
wire        name_music = (ent_name == 64'h4D55534943202020);
wire        name_picture = (ent_name == 64'h5049435455524520);   // "PICTURE "
wire        name_lyric   = (ent_name == 64'h4C59524943202020);   // "LYRIC   "
wire        name_ui_bin  = (ent_name == 64'h4C56474C20202020) &&
                           (ent_ext == 24'h42494E);
wire        name_lyric_dir = name_lyric;                         // 根目录里的 LYRIC 文件夹
// 目录优先：找到 PICTURE 文件夹就从它第一个扇区开始找图；否则退回数据区起点
// pic_first_r 在条目解析完成那一拍算好寄存（见各处 ent_last 分支）
// MUSIC 目录没找到时退回全盘扫描：这样音频的“扇区魔数”兜底仍然有效
wire [31:0] scan_base   = (pic_found && music_found) ? pic_first_r : fs_abs_r;
// LYRIC.BIN 的绝对起始扇区（字幕模块按它读文件）
assign lyric_start_sector = lyric_first_r;
assign lyric_valid        = lyric_found && fs_start_ok && (lyric_clu >= 32'd2);
wire [31:0] spc_sectors= (32'd1 << spc_log2_r);
wire [31:0] root_clu_w = {dbr_root_3, dbr_root_2, dbr_root_1, dbr_root_0};
wire        hdr_is_bmp      = (header_0 == "B") && (header_1 == "M") &&
                              (file_len > 32'd54) && (file_len <= 32'd8_388_608) &&
                              (pixel_offset >= 32'd54) && (pixel_offset < file_len);
assign dbg_fs_kind = {fs_kind_r, spc_log2_r};
assign dbg_dir_flags = {dir_used, music_found, pic_found, audio_found};
// 扫描起点：exFAT 用簇堆偏移，FAT16/32 用"保留+FAT"，都拿到就用，否则退回 0 扫
wire [31:0] fs_data_start    = is_exfat ? exfat_data_start : dbr_data_start;
// spc_log2_r 要下一拍才有效，这里给一个同拍可用的组合版本
wire [3:0]  spc_log2_w = is_exfat ? exfat_spc_shift[3:0] : fat_spc_log2(dbr_spc);
// 当前读到的扇区是不是合法的文件系统引导扇区
wire        fs_sig_ok        = (dbr_sig_lo == 8'h55) && (dbr_sig_hi == 8'hAA) &&
                               (is_exfat ||
                                (((dbr_first_byte == 8'hEB) || (dbr_first_byte == 8'hE9)) &&
                                 (dbr_bps_lo == 8'h00) && (dbr_bps_hi == 8'h02)));

assign ready = (state == ST_IDLE);
// 图片识别：不再限定 640x480，改由 bmp_fit_stream 等比铺满/居中裁切
//（限定：24bit 未压缩、正高度、边长 1~4096、文件 <= 4MB —— 4MB 是 SD 读取超时余量）
localparam [15:0] FIT_MAX_DIM = 16'd4096;
localparam [31:0] FIT_MAX_LEN = 32'd4_194_304;
assign header_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0) &&
                      (width[31:16] == 16'd0)  && (width[15:0]  >= 16'd1) && (width[15:0]  <= FIT_MAX_DIM) &&
                      (height[31:16] == 16'd0) && (height[15:0] >= 16'd1) && (height[15:0] <= FIT_MAX_DIM) &&
                      (pixel_offset >= 32'd54) && (file_len > pixel_offset) &&
                      (file_len <= FIT_MAX_LEN);
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt <  file_len);
// 下一扫描地址寄存：只依赖 scan_sector 与已寄存的跳转量，
// 到 sd_sec_read_end 时直接取用，加法不再出现在扫描寄存器的使能路径上。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        scan_next_match_r <= 32'd0;
        scan_next_miss_r  <= 32'd0;
        scan_next_bmp_r   <= 32'd0;
        scan_next_audio_r <= 32'd0;
    end else begin
        scan_next_match_r <= scan_sector + file_sector_count_r;
        scan_next_miss_r  <= scan_sector + 32'd1;
        scan_next_bmp_r   <= scan_sector + hdr_file_sectors_r;
        scan_next_audio_r <= scan_sector + audio_skip_sectors_r;
    end
end

// 文件长度派生量寄存：file_len 在扇区头部第 2~5 字节就锁存好，
// 而 header_match / hdr_is_bmp / 跳转扇区数都只在 sd_sec_read_end 用到，
// 相隔数百拍，因此延后一拍完全安全。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        file_sector_count_r <= 32'd1;
        hdr_file_sectors_r  <= 32'd0;
        audio_skip_sectors_r<= 32'd1;
        header_match_r      <= 1'b0;
        hdr_is_bmp_r        <= 1'b0;
        fs_data_start_r     <= 32'd0;
    end else begin
        file_sector_count_r <= (file_len == 32'd0) ? 32'd1 : ((file_len + 32'd511) >> 9);
        hdr_file_sectors_r  <= (file_len + 32'd511) >> 9;
        audio_skip_sectors_r<= 32'd1 + ((({audio_fr[29:0], 2'b00}) + 32'd511) >> 9);
        header_match_r      <= header_match;
        hdr_is_bmp_r        <= hdr_is_bmp;
        fs_data_start_r     <= fs_data_start;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR) || (state == ST_DBR) ||
                 (state == ST_ROOT) || (state == ST_MUSIC) || (state == ST_PROBE_AUD) || (state == ST_LDIR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
        scan_magic_shift <= 64'd0;
        audio_fr         <= 32'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR) || (state == ST_PROBE_AUD)) && sd_sec_read_data_valid) begin
        if (rd_cnt <= 10'd7)
            scan_magic_shift <= {scan_magic_shift[55:0], sd_sec_read_data};
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd8 : audio_fr[7:0]   <= sd_sec_read_data;
            10'd9 : audio_fr[15:8]  <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: begin pixel_offset[7:0] <= sd_sec_read_data; audio_fr[23:16] <= sd_sec_read_data; end
            10'd11: begin pixel_offset[15:8] <= sd_sec_read_data; audio_fr[31:24] <= sd_sec_read_data; end
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

// ---------------------------------------------------------------------------
// 引导扇区解析：从 DBR 里读出“数据区起点”，扫描直接从数据区开始，
// 避免在大容量卡上把十几 MB 的 FAT 区逐扇区走一遍（那要十几秒，看起来像死机）。
// 扇区 0 可能是 MBR（分区表），此时按分区表里的 LBA 再读一次分区引导扇区。
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst) begin
        dbr_first_byte <= 8'h00;
        dbr_bps_lo     <= 8'd0;
        dbr_bps_hi     <= 8'd0;
        dbr_spc        <= 8'd0;
        dbr_rsv_lo     <= 8'd0;
        dbr_rsv_hi     <= 8'd0;
        dbr_nfat       <= 8'd0;
        dbr_spf16_lo   <= 8'd0;
        dbr_spf16_hi   <= 8'd0;
        dbr_spf32_0    <= 8'd0;
        dbr_spf32_1    <= 8'd0;
        dbr_spf32_2    <= 8'd0;
        dbr_spf32_3    <= 8'd0;
        exfat_sig3     <= 8'd0;
        exfat_sig4     <= 8'd0;
        exfat_sig5     <= 8'd0;
        exfat_sig6     <= 8'd0;
        exfat_spc_shift<= 8'd0;
        exfat_heap_0   <= 8'd0;
        exfat_heap_1   <= 8'd0;
        exfat_heap_2   <= 8'd0;
        exfat_heap_3   <= 8'd0;
        mbr_part_lba   <= 32'd0;
        dbr_sig_lo     <= 8'd0;
        dbr_root_0     <= 8'd0;
        dbr_root_1     <= 8'd0;
        dbr_root_2     <= 8'd0;
        dbr_root_3     <= 8'd0;
        dbr_sig_hi     <= 8'd0;
    end else if ((state == ST_DBR) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0  : dbr_first_byte <= sd_sec_read_data;
            10'd11 : dbr_bps_lo     <= sd_sec_read_data;
            10'd12 : dbr_bps_hi     <= sd_sec_read_data;
            10'd13 : dbr_spc        <= sd_sec_read_data;
            10'd14 : dbr_rsv_lo     <= sd_sec_read_data;
            10'd15 : dbr_rsv_hi     <= sd_sec_read_data;
            10'd16 : dbr_nfat       <= sd_sec_read_data;
            10'd22 : dbr_spf16_lo   <= sd_sec_read_data;
            10'd23 : dbr_spf16_hi   <= sd_sec_read_data;
            10'd36 : dbr_spf32_0    <= sd_sec_read_data;
            10'd37 : dbr_spf32_1    <= sd_sec_read_data;
            10'd38 : dbr_spf32_2    <= sd_sec_read_data;
            10'd39 : dbr_spf32_3    <= sd_sec_read_data;
            10'd44 : dbr_root_0     <= sd_sec_read_data;   // FAT32 root cluster 0x2C
            10'd45 : dbr_root_1     <= sd_sec_read_data;
            10'd46 : dbr_root_2     <= sd_sec_read_data;
            10'd47 : dbr_root_3     <= sd_sec_read_data;
            10'd3  : exfat_sig3     <= sd_sec_read_data;
            10'd4  : exfat_sig4     <= sd_sec_read_data;
            10'd5  : exfat_sig5     <= sd_sec_read_data;
            10'd6  : exfat_sig6     <= sd_sec_read_data;
            10'd109: exfat_spc_shift<= sd_sec_read_data;   // 0x6D 每簇扇区数移位
            10'd88 : exfat_heap_0   <= sd_sec_read_data;   // 0x58 簇堆起始扇区
            10'd89 : exfat_heap_1   <= sd_sec_read_data;
            10'd90 : exfat_heap_2   <= sd_sec_read_data;
            10'd91 : exfat_heap_3   <= sd_sec_read_data;
            10'd454: mbr_part_lba[7:0]   <= sd_sec_read_data;
            10'd455: mbr_part_lba[15:8]  <= sd_sec_read_data;
            10'd456: mbr_part_lba[23:16] <= sd_sec_read_data;
            10'd457: mbr_part_lba[31:24] <= sd_sec_read_data;
            10'd510: dbr_sig_lo     <= sd_sec_read_data;
            10'd511: dbr_sig_hi     <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

// ---------------------------------------------------------------------------
// 图片自适应缩放：任意尺寸 24bit BMP → 恒定 640x480 像素流
//   等比放大/缩小与居中裁切在 bmp_fit_stream 内完成，输出恒为完整目标帧。
//   节流：can_accept=0 时不发新扇区请求，给“在途扇区”留出 FIFO 余量。
// ---------------------------------------------------------------------------
localparam integer FRAME_WD = 640;
localparam integer FRAME_HT = 480;
localparam [15:0]  STARVE_LIMIT = 16'd256;   // 源字节读完还等像素 → 判定文件截断

reg         fit_start;
reg         fit_abort;
reg  [15:0] fit_w_lat, fit_h_lat;
reg  [15:0] starve_cnt;
wire        fit_busy;
wire        fit_done;
wire        fit_starving;
wire        fit_ovf;
wire        fit_can_accept;
wire [31:0] fit_pix_cnt;
wire [15:0] fit_out_w, fit_out_h;
wire        src_need_more = (bmp_len_cnt < file_len);
wire        fit_src_valid = (state == ST_LOAD_DATA) && bmp_data_valid;

assign dbg_fit_w = fit_out_w;
assign dbg_fit_h = fit_out_h;

bmp_fit_stream #(
    .FRAME_W (FRAME_WD),
    .FRAME_H (FRAME_HT)
) u_fit (
    .clk        (clk),
    .rst        (rst),
    .start      (fit_start),
    .abort      (fit_abort),
    .img_w      (fit_w_lat),
    .img_h      (fit_h_lat),
    .src_valid  (fit_src_valid),
    .src_byte   (sd_sec_read_data),
    .out_valid  (bmp_data_wr_en),
    .out_data   (bmp_data),
    .busy       (fit_busy),
    .frame_done (fit_done),
    .starving   (fit_starving),
    .fifo_ovf   (fit_ovf),
    .pix_cnt    (fit_pix_cnt),
    .out_w_dbg  (fit_out_w),
    .out_h_dbg  (fit_out_h),
    .can_accept (fit_can_accept)
);

// 源字节已全部读完、整形器还在等像素（文件被截断）→ 计数到上限就放弃本次加载
always @(posedge clk or posedge rst) begin
    if (rst) begin
        starve_cnt <= 16'd0;
    end else if (state != ST_LOAD_DATA) begin
        starve_cnt <= 16'd0;
    end else if (!src_need_more && fit_starving && !sd_sec_read) begin
        if (starve_cnt != STARVE_LIMIT)
            starve_cnt <= starve_cnt + 16'd1;
    end else if (starve_cnt != 16'd0) begin
        starve_cnt <= 16'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        picture_started   <= 1'b0;
        pic_found         <= 1'b0;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 6'd0;
        scan_sector       <= 32'd0;
        scan_miss_cnt     <= 32'd0;
        load_sector_latched <= 32'd0;
        fs_kind_r         <= 4'd0;
        spc_log2_r        <= 4'd6;
        fit_start         <= 1'b0;
        fit_abort         <= 1'b0;
        fit_w_lat         <= 16'd0;
        fit_h_lat         <= 16'd0;
        music_first_r     <= 32'd0;
        pic_first_r       <= 32'd0;
        file_first_r      <= 32'd0;
        lyric_first_r     <= 32'd0;
        root_off_r        <= 32'd0;
        ui_file_valid     <= 1'b0;
        ui_file_sector    <= 32'd0;
        ui_file_bytes     <= 32'd0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        picture_started   <= 1'b0;
        pic_found         <= 1'b0;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 6'd0;
        scan_sector       <= 32'd0;
        scan_miss_cnt     <= 32'd0;
        load_sector_latched <= 32'd0;
        fit_abort         <= 1'b1;
        music_first_r     <= 32'd0;
        pic_first_r       <= 32'd0;
        file_first_r      <= 32'd0;
        lyric_first_r     <= 32'd0;
        root_off_r        <= 32'd0;
        ui_file_valid     <= 1'b0;
        ui_file_sector    <= 32'd0;
        ui_file_bytes     <= 32'd0;
    end else if (load_abort) begin
        // 单张图加载超时只中止这次加载，扫描结果（scan_done/sector 表）必须保留，
        // 否则 sd_card_bmp 里依赖 scan_done 的“按需加载”路径会一起失效。
        state             <= ST_IDLE;
        state_code        <= 4'd1;
        sd_sec_read       <= 1'b0;
        write_req         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_miss_cnt     <= 32'd0;
        fit_abort         <= 1'b1;      // 让整形器一起回空闲，别把半帧像素留给下一张
    end else begin
        scan_found_valid <= 1'b0;
        fit_abort        <= 1'b0;
        fit_start        <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= picture_error != 0 ? 4'd15 : 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    picture_started  <= 1'b0;
                    pic_found        <= 1'b0;
                    scan_done        <= 1'b0;
                    scan_found_total <= 6'd0;
                    scan_miss_cnt    <= 32'd0;
                    // 先读引导扇区算出数据区起点，再开始扫描
                    dbr_retry        <= 1'b0;
                    dbr_probe        <= 4'd0;
                    vol_lba          <= 32'd0;
                    // 文件系统类型/簇大小在 ST_DBR 解析成功后写入
                    scan_gap_active  <= scan_gap_limit;
                    audio_found      <= 1'b0;
                    ui_file_valid    <= 1'b0;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_DBR;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_DBR: begin
                state_code  <= 4'd7;      // 7 = 正在解析文件系统引导扇区
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (fs_sig_ok) begin
                        // 一级：只算数据区起点并寄存，避免长组合路径
                        fs_start_r  <= fs_data_start_r;
                        fs_kind_r  <= is_exfat ? 4'd2 : 4'd1;
                        spc_log2_r <= spc_log2_w;
                        root_off_r <= (root_clu_w - 32'd2) << spc_log2_w;
                        fs_start_ok <= (fs_data_start_r != 32'd0) &&
                                       (fs_data_start_r[31:24] == 8'd0);  // <8GB 的粗校验
                        state       <= ST_DBR2;
                    end else if ((dbr_sig_lo == 8'h55) && (dbr_sig_hi == 8'hAA) &&
                                 (mbr_part_lba != 32'd0) && !dbr_retry) begin
                        // 扇区 0 是 MBR：按分区表再读一次分区引导扇区
                        vol_lba          <= mbr_part_lba;      // 卷起点
                        sd_sec_read_addr <= mbr_part_lba;      // 注意：真正的读地址是它
                        dbr_retry        <= 1'b1;
                    end else if (probe_lba(dbr_probe) != 32'd0) begin
                        // MBR 里没找到分区表：换个常见的分区起点再试
                        vol_lba          <= probe_lba(dbr_probe);
                        sd_sec_read_addr <= probe_lba(dbr_probe);
                        dbr_probe        <= dbr_probe + 4'd1;
                    end else begin
                        // 解析不出来 → 走兜底
                        fs_start_ok <= 1'b0;
                        state       <= ST_DBR2;
                    end
                end
            end

            ST_DBR2: begin
                state_code <= 4'd7;
                // 数据区绝对扇区 = 卷起始 LBA + 卷内数据区偏移
                fs_abs_r <= vol_lba + fs_start_r;
                state    <= ST_DBR3;
            end

            ST_DBR3: begin
                state_code <= 4'd7;
                if (fs_start_ok) begin
                    scan_sector      <= fs_abs_r;
                    sd_sec_read_addr <= fs_abs_r;
                    scan_gap_active  <= gap_auto;            // 按簇大小自适应（2 簇）
                end else begin
                    // 兜底：从 scan_start_sector 开始扫，允许走很远去找图
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    scan_gap_active  <= gap_auto;            // 按簇大小自适应（2 簇）
                end
                if (fs_start_ok && !is_exfat && (root_clu_w >= 32'd2)) begin
                    root_clu         <= root_clu_w;
                    root_first       <= fs_abs_r + root_off_r;
                    sd_sec_read_addr <= fs_abs_r + root_off_r;
                    dir_k            <= 8'd0;
                    music_found      <= 1'b0;
                    pic_found        <= 1'b0;
                    lyric_found      <= 1'b0;
                    music_first_r    <= 32'd0;
                    pic_first_r      <= 32'd0;
                    lyric_first_r    <= 32'd0;
                    file_first_r     <= 32'd0;
                    ldir_found       <= 1'b0;
                    file_hit         <= 1'b0;
                    resume_ent       <= 5'd0;
                    dir_used         <= 1'b1;
                    state            <= ST_ROOT;
                end else begin
                    state <= ST_SCAN;
                end
            end

            ST_ROOT: begin
                state_code  <= 4'd7;
                sd_sec_read <= 1'b1;
                if (sd_sec_read_data_valid) begin
                    case (ent_byte)
                        5'd0 : begin ent_first <= sd_sec_read_data; ent_name <= {56'd0, sd_sec_read_data}; end
                        5'd1, 5'd2, 5'd3, 5'd4, 5'd5, 5'd6, 5'd7 :
                            ent_name <= {ent_name[55:0], sd_sec_read_data};
                        5'd8 : ent_ext[23:16] <= sd_sec_read_data;
                        5'd9 : ent_ext[15:8] <= sd_sec_read_data;
                        5'd10: ent_ext[7:0] <= sd_sec_read_data;
                        5'd11: ent_attr   <= sd_sec_read_data;
                        5'd20: ent_ch_lo0 <= sd_sec_read_data;
                        5'd21: ent_ch_hi0 <= sd_sec_read_data;
                        5'd26: ent_cl_lo0 <= sd_sec_read_data;
                        5'd27: ent_cl_hi0 <= sd_sec_read_data;
                        5'd28: ent_size_lo[7:0] <= sd_sec_read_data;
                        5'd29: ent_size_lo[15:8] <= sd_sec_read_data;
                        5'd30: ent_size_lo[23:16] <= sd_sec_read_data;
                        default: ;
                    endcase
                    if (ent_last && ent_valid && ent_is_dir && name_music) begin
                        music_clu   <= ent_clu;
                        music_found <= 1'b1;
                        music_first_r <= fs_abs_r + (ent_clu_m2_r << spc_log2_r);
                    end
                    if (ent_last && ent_valid && ent_is_dir && name_picture) begin
                        pic_clu   <= ent_clu;
                        pic_found <= 1'b1;
                        pic_first_r <= fs_abs_r + (ent_clu_m2_r << spc_log2_r);
                    end
                    if (ent_last && ent_is_file && name_lyric) begin
                        lyric_clu   <= ent_clu;
                        lyric_found <= 1'b1;
                        lyric_first_r <= fs_abs_r + (ent_clu_m2_r << spc_log2_r);
                    end
                    if (ent_last && ent_is_file && name_ui_bin) begin
                        ui_file_valid <= 1'b1;
                        ui_file_sector <= fs_abs_r +
                                          (ent_clu_m2_r << spc_log2_r);
                        ui_file_bytes <= {sd_sec_read_data, ent_size_lo};
                    end
                    // 根目录里的 LYRIC 文件夹（歌词按"和歌同名"放在这里面）
                    if (ent_last && ent_valid && ent_is_dir && name_lyric_dir) begin
                        ldir_clu   <= ent_clu;
                        ldir_found <= 1'b1;
                        ldir_first <= fs_abs_r + (ent_clu_m2_r << spc_log2_r);
                    end
                end
                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    // 必须把整个根目录簇扫完再走：MUSIC / PICTURE / LYRIC.BIN
                    // 三个目录项不一定落在同一个扇区（卡上删过文件会留下空槽），
                    // 之前"一找到 MUSIC 就收工"会让后面的条目永远看不到。
                    if (({24'd0, dir_k} + 32'd1) < spc_sectors) begin
                        dir_k            <= dir_k + 8'd1;
                        sd_sec_read_addr <= root_first + {24'd0, dir_k} + 32'd1;
                    end else if (music_found) begin
                        dir_sector       <= music_first_r;
                        sd_sec_read_addr <= music_first_r;
                        dir_k            <= 8'd0;
                        resume_ent       <= 5'd0;
                        file_hit         <= 1'b0;
                        state            <= ST_MUSIC;
                    end else begin
                        // 根目录扫完：MUSIC 没找到也没关系，图片从 PICTURE 开始扫
                        dir_used         <= pic_found && music_found;
                        scan_sector      <= scan_base;
                        sd_sec_read_addr <= scan_base;
                        state            <= ST_SCAN;
                    end
                end
            end

            ST_MUSIC: begin
                state_code  <= 4'd7;
                sd_sec_read <= 1'b1;
                if (sd_sec_read_data_valid) begin
                    case (ent_byte)
                        5'd0 : begin ent_first <= sd_sec_read_data; ent_name <= {56'd0, sd_sec_read_data}; end
                        5'd1, 5'd2, 5'd3, 5'd4, 5'd5, 5'd6, 5'd7 :
                            ent_name <= {ent_name[55:0], sd_sec_read_data};
                        5'd11: ent_attr   <= sd_sec_read_data;
                        5'd20: ent_ch_lo0 <= sd_sec_read_data;
                        5'd21: ent_ch_hi0 <= sd_sec_read_data;
                        5'd26: ent_cl_lo0 <= sd_sec_read_data;
                        5'd27: ent_cl_hi0 <= sd_sec_read_data;
                        default: ;
                    endcase
                    if (ent_last && !file_hit && ({1'b0, ent_now} >= resume_ent) && ent_is_file) begin
                        file_hit <= 1'b1;
                        file_clu <= ent_clu;
                        file_ent <= ent_now;
                        file_first_r <= fs_abs_r + (ent_clu_m2_r << spc_log2_r);
                        audio_name <= ent_name;      // 记住歌名，去 LYRIC 目录找同名歌词
                    end
                end
                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (file_hit) begin
                        probe_sector     <= file_first_r;
                        sd_sec_read_addr <= file_first_r;
                        resume_ent       <= {1'b0, file_ent} + 5'd1;
                        state            <= ST_PROBE_AUD;
                    end else if (({24'd0, dir_k} + 32'd1) < spc_sectors) begin
                        dir_k            <= dir_k + 8'd1;
                        resume_ent       <= 5'd0;
                        sd_sec_read_addr <= dir_sector + {24'd0, dir_k} + 32'd1;
                    end else begin
                        // MUSIC 目录里没有可用的音频文件：图片照常从 PICTURE 开始扫
                        dir_used         <= pic_found && music_found;
                        scan_sector      <= scan_base;
                        sd_sec_read_addr <= scan_base;
                        state            <= ST_SCAN;
                    end
                end
            end

            ST_PROBE_AUD: begin
                state_code  <= 4'd7;
                sd_sec_read <= 1'b1;
                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (audio_magic_ok) begin
                        audio_found        <= 1'b1;
                        audio_start_sector <= probe_sector;
                        audio_frames       <= audio_fr;
                        // 音频已定位：图片从 PICTURE 目录开始扫（找不到就退回数据区起点）
                        dir_used         <= pic_found && music_found;
                        if (ldir_found) begin
                            // 根目录有 LYRIC 文件夹 → 去里面找"和歌同名"的歌词文件
                            sd_sec_read_addr <= ldir_first;
                            dir_k            <= 8'd0;
                            state            <= ST_LDIR;
                        end else begin
                            scan_sector      <= scan_base;
                            sd_sec_read_addr <= scan_base;
                            scan_gap_active  <= gap_auto;
                            state            <= ST_SCAN;
                        end
                    end else begin
                        // 不是音频文件：回到 MUSIC 目录继续找下一个条目
                        sd_sec_read_addr <= dir_sector + {24'd0, dir_k};
                        state            <= ST_MUSIC;
                    end
                end
            end

            // ---- LYRIC 目录：找和歌同名的歌词文件（8.3 名字按字节比较）----
            ST_LDIR: begin
                state_code  <= 4'd7;
                sd_sec_read <= 1'b1;
                if (sd_sec_read_data_valid) begin
                    case (ent_byte)
                        5'd0 : begin ent_first <= sd_sec_read_data; ent_name <= {56'd0, sd_sec_read_data}; end
                        5'd1, 5'd2, 5'd3, 5'd4, 5'd5, 5'd6, 5'd7 :
                            ent_name <= {ent_name[55:0], sd_sec_read_data};
                        5'd8: ent_ext[23:16] <= sd_sec_read_data;
                        5'd9: ent_ext[15:8] <= sd_sec_read_data;
                        5'd10: ent_ext[7:0] <= sd_sec_read_data;
                        5'd11: ent_attr   <= sd_sec_read_data;
                        5'd20: ent_ch_lo0 <= sd_sec_read_data;
                        5'd21: ent_ch_hi0 <= sd_sec_read_data;
                        5'd26: ent_cl_lo0 <= sd_sec_read_data;
                        5'd27: ent_cl_hi0 <= sd_sec_read_data;
                        5'd28: ent_size_lo[7:0] <= sd_sec_read_data;
                        5'd29: ent_size_lo[15:8] <= sd_sec_read_data;
                        5'd30: ent_size_lo[23:16] <= sd_sec_read_data;
                        default: ;
                    endcase
                    if (ent_last && ent_is_file && (ent_name == audio_name)) begin
                        lyric_clu   <= ent_clu;
                        lyric_found <= 1'b1;
                    end
                end
                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (lyric_found || (({24'd0, dir_k} + 32'd1) >= spc_sectors)) begin
                        // 找到或目录扫完 → 去扫图片
                        scan_sector      <= scan_base;
                        sd_sec_read_addr <= scan_base;
                        scan_gap_active  <= gap_auto;
                        state            <= ST_SCAN;
                    end else begin
                        dir_k            <= dir_k + 8'd1;
                        sd_sec_read_addr <= ldir_first + {24'd0, dir_k} + 32'd1;
                    end
                end
            end

            ST_SCAN: begin
                picture_started <= 1'b1;
                state_code <= picture_error != 0 ? 4'd15 : 4'd2;
                sd_sec_read <= picture_request && !sd_sec_read_end;
                sd_sec_read_addr <= picture_address;
                if (picture_found) begin
                    scan_found_valid <= 1'b1;
                    scan_found_sector <= picture_sector;
                    scan_sector <= picture_sector;
                    scan_found_total <= scan_found_total + 6'd1;
                end
                if (picture_done) begin
                    scan_done <= 1'b1;
                    sd_sec_read <= 1'b0;
                    state <= ST_IDLE;
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match_r) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        // 把源图尺寸交给整形器：它负责等比缩放 + 居中补黑
                        fit_w_lat        <= width[15:0];
                        fit_h_lat        <= height[15:0];
                        fit_start        <= 1'b1;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code <= 4'd4;

                // 一个扇区读完：先撤请求；文件没读完就把地址推进到下一个扇区
                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (src_need_more)
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                end

                // 整帧吐完 / FIFO 溢出 / 源文件截断 → 收工
                //（等本扇区收尾再走，避免把 SD 读打断在半路）
                if (fit_done || fit_ovf || (starve_cnt >= STARVE_LIMIT)) begin
                    if (!sd_sec_read)
                        state <= ST_IDLE;
                end else if (!sd_sec_read && src_need_more && fit_can_accept) begin
                    // 节流：整形器 FIFO 有余量才发下一个扇区请求
                    sd_sec_read <= 1'b1;
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

picture_directory u_picture_directory (
    .clk(clk), .rst(rst || !sd_init_done || scan_start),
    .start(state == ST_SCAN && !picture_started),
    .present(pic_found && fs_start_ok && !is_exfat),
    .first_cluster(pic_clu), .data_base(fs_abs_r),
    .fat_base(vol_lba + dbr_reserved), .cluster_shift(spc_log2_r),
    .target_count(scan_target_count), .data(sd_sec_read_data),
    .valid(sd_sec_read_data_valid && state == ST_SCAN),
    .ending(sd_sec_read_end && state == ST_SCAN),
    .header_ok(header_match_r), .header_bytes(file_len),
    .request(picture_request), .done(picture_done), .found(picture_found),
    .address(picture_address), .found_sector(picture_sector), .error(picture_error)
);
endmodule
