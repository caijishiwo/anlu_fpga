// ---------------------------------------------------------------------------
// cpu_sdram_bridge —— 把 picosoc32 的 iomem 接口接到媒体工程的 SDRAM 通路上
//
//   CPU 侧 : clk_cpu (25MHz)。每个 valid && ready 时钟沿完成一次事务。
//   SDRAM 侧: clk_mem (62.5MHz)，经仲裁器驱动 sdram_ctrl 的 app 接口。
//
//   跨域方式：单比特「翻转位」握手。请求字段（addr/wstrb/wdata）在 CPU 侧
//   一直保持到 ack 回来，属于「稳定数据 + 单比特握手」的经典模式；回读数据
//   (rdata_mem) 在 ack 翻转前就已稳定，CPU 侧在识别到 ack 时才采样。
//   约束文件里要对这两组跨域路径加 set_false_path。
//
//   时序语义（照 sdram_ctrl/sdr_as_ram 的用法）：
//     - 任何操作都要等 Sdr_init_done 之后才发；
//     - 写：App_wr_en 拉高 1 拍，同时给出 addr/din/dm（dm 高=屏蔽该字节）；
//     - 读：App_rd_en 拉高 1 拍，之后等 Sdr_rd_en 脉冲带回 Sdr_rd_dout。
//
//   写授权可以提前返回 CPU；仲裁器保持占用并完成写后读屏障，
//   后续事务必须重新授权，不能越过仍在排空的写流水线。
// ---------------------------------------------------------------------------

module cpu_sdram_bridge #(
    parameter ENABLE_INSTRUCTION_CACHE = 0
) (
    // ---- CPU 侧（clk_cpu） ----
    input             clk_cpu,
    input             rst_cpu_n,
    input             valid,
    input             instr,
    input      [3:0]  wstrb,
    input      [20:0] word_addr,
    input      [31:0] wdata,
    output reg        ready,
    output reg [31:0] rdata,

    // ---- SDRAM 侧（clk_mem） ----
    input             clk_mem,
    input             rst_mem_n,
    input             sdr_init_done,
    output wire       app_req,
    output wire       app_is_write,
    input             app_grant,
    output wire       app_wr_en,
    output wire [20:0] app_wr_addr,
    output wire [3:0] app_wr_dm,
    output wire [31:0] app_wr_din,
    output wire       app_rd_en,
    output wire [20:0] app_rd_addr,
    input             sdr_rd_en,
    input      [31:0] sdr_rd_dout
);

    localparam CPU_IDLE = 2'd0;
    localparam CPU_WAIT = 2'd1;
    localparam CPU_HOLD = 2'd2;
    localparam CPU_LOOKUP = 2'd3;
    localparam CACHE_INDEX_BITS = 8;
    localparam CACHE_LINES = 1 << CACHE_INDEX_BITS;
    localparam CACHE_TAG_BITS = 21 - CACHE_INDEX_BITS;
    localparam CACHE_WORD_BITS = 33 + CACHE_TAG_BITS;
    reg [CACHE_WORD_BITS-1:0] instruction_cache [0:CACHE_LINES-1]
        /* synthesis syn_ramstyle = "block_ram" */;
    reg [CACHE_WORD_BITS-1:0] cached_word;
    reg cache_initialized;
    reg [CACHE_INDEX_BITS-1:0] clear_index;
    reg req_instr;

    localparam MEM_IDLE    = 2'd0;
    localparam MEM_ISSUE   = 2'd1;
    localparam MEM_WAIT_RD = 2'd2;
    localparam MEM_DONE    = 2'd3;

    // 请求字段 + 请求翻转位（CPU 域产生，mem 域采样）
    reg        req_tgl;
    reg [20:0] req_addr;
    reg [31:0] req_wdata;
    reg [3:0]  req_wstrb;
    reg        req_is_wr;
    wire [CACHE_INDEX_BITS-1:0] cache_index = req_addr[CACHE_INDEX_BITS-1:0];
    wire cache_hit = cached_word[CACHE_WORD_BITS-1] &&
        cached_word[CACHE_WORD_BITS-2:32] == req_addr[20:CACHE_INDEX_BITS];

    // 应答翻转位 + 回读数据（mem 域产生，CPU 域采样）
    reg        ack_tgl;
    reg [31:0] rdata_mem;

    reg [1:0]  cpu_state;
    reg [1:0]  mem_state;
    reg [20:0] op_addr;
    reg [31:0] op_wdata;
    reg [3:0]  op_wstrb;
    reg        op_is_wr;

    assign app_req = mem_state == MEM_ISSUE;
    assign app_is_write = op_is_wr;
    assign app_wr_en = app_req && app_grant && op_is_wr;
    assign app_rd_en = app_req && app_grant && !op_is_wr;
    assign app_wr_addr = op_addr;
    assign app_rd_addr = op_addr;
    assign app_wr_dm = ~op_wstrb;
    assign app_wr_din = op_wdata;

    // 同步器
    reg ack_sync0, ack_sync1;   // ack_tgl -> clk_cpu
    reg req_sync0, req_sync1;   // req_tgl -> clk_mem

    // 同步读以推断片上 RAM；缓存只服务取指，数据和启动校验直通 SDRAM。
    always @(posedge clk_cpu) begin
        cached_word <= instruction_cache[word_addr[CACHE_INDEX_BITS-1:0]];
        if (ENABLE_INSTRUCTION_CACHE && !cache_initialized)
            instruction_cache[clear_index] <= 0;
        else if (cpu_state == CPU_IDLE && valid && |wstrb)
            instruction_cache[word_addr[CACHE_INDEX_BITS-1:0]] <= 0;
        else if (rst_cpu_n && cpu_state == CPU_WAIT && ack_sync1 == req_tgl && req_instr)
            instruction_cache[cache_index] <= {1'b1, req_addr[20:CACHE_INDEX_BITS], rdata_mem};
    end

    // 上电逐行清有效位，256 拍后才接受访问；不依赖 RAM 的上电内容。
    always @(posedge clk_cpu) begin
        if (!rst_cpu_n) begin
            clear_index <= 0;
            cache_initialized <= 0;
        end else if (!cache_initialized) begin
            clear_index <= clear_index + 1'b1;
            if (clear_index == CACHE_LINES-1) cache_initialized <= 1;
        end
    end

    always @(posedge clk_cpu) begin
        if (!rst_cpu_n) begin
            ack_sync0 <= 1'b0;
            ack_sync1 <= 1'b0;
        end else begin
            ack_sync0 <= ack_tgl;
            ack_sync1 <= ack_sync0;
        end
    end

    always @(posedge clk_mem) begin
        if (!rst_mem_n) begin
            req_sync0 <= 1'b0;
            req_sync1 <= 1'b0;
        end else begin
            req_sync0 <= req_tgl;
            req_sync1 <= req_sync0;
        end
    end

    // ---------------- CPU 侧 ----------------
    always @(posedge clk_cpu) begin
        if (!rst_cpu_n) begin
            cpu_state <= CPU_IDLE;
            req_tgl   <= 1'b0;
            req_addr  <= 21'd0;
            req_wdata <= 32'd0;
            req_wstrb <= 4'd0;
            req_is_wr <= 1'b0;
            ready     <= 1'b0;
            rdata     <= 32'd0;
            req_instr <= 0;
        end else begin
            case (cpu_state)
                CPU_IDLE: begin
                    ready <= 1'b0;
                    if (valid && (!ENABLE_INSTRUCTION_CACHE || cache_initialized)) begin
                        req_addr  <= word_addr;
                        req_wdata <= wdata;
                        req_wstrb <= wstrb;
                        req_is_wr <= (wstrb != 4'b0000);
                        req_instr <= ENABLE_INSTRUCTION_CACHE && instr && wstrb == 0;
                        if (ENABLE_INSTRUCTION_CACHE && instr && wstrb == 0)
                            cpu_state <= CPU_LOOKUP;
                        else begin
                            req_tgl <= ~req_tgl;
                            cpu_state <= CPU_WAIT;
                        end
                    end
                end

                CPU_LOOKUP: begin
                    if (cache_hit) begin
                        rdata <= cached_word[31:0];
                        ready <= 1;
                        cpu_state <= CPU_HOLD;
                    end else begin
                        req_tgl <= ~req_tgl;
                        cpu_state <= CPU_WAIT;
                    end
                end
                CPU_WAIT: begin
                    if (ack_sync1 == req_tgl) begin
                        rdata     <= rdata_mem;
                        ready     <= 1'b1;
                        cpu_state <= CPU_HOLD;
                    end
                end

                // ready 本拍完成一次握手；跨字取指可保持 valid 并立即换地址。
                CPU_HOLD: begin
                    ready     <= 1'b0;
                    cpu_state <= CPU_IDLE;
                end

                default: cpu_state <= CPU_IDLE;
            endcase
        end
    end

    // ---------------- SDRAM 侧 ----------------
    always @(posedge clk_mem) begin
        if (!rst_mem_n) begin
            mem_state  <= MEM_IDLE;
            ack_tgl    <= 1'b0;
            rdata_mem  <= 32'd0;
            op_addr    <= 21'd0;
            op_wdata   <= 32'd0;
            op_wstrb   <= 4'd0;
            op_is_wr   <= 1'b0;
        end else begin

            case (mem_state)
                MEM_IDLE: begin
                    // 请求字段此刻已稳定，可以安全采样
                    if ((req_sync1 != ack_tgl) && sdr_init_done) begin
                        op_addr   <= req_addr;
                        op_wdata  <= req_wdata;
                        op_wstrb  <= req_wstrb;
                        op_is_wr  <= req_is_wr;
                        mem_state <= MEM_ISSUE;
                    end
                end

                MEM_ISSUE: begin
                    if (app_grant)
                        mem_state <= op_is_wr ? MEM_DONE : MEM_WAIT_RD;
                end

                MEM_WAIT_RD: begin
                    if (sdr_rd_en) begin
                        rdata_mem <= sdr_rd_dout;
                        mem_state <= MEM_DONE;
                    end
                end

                MEM_DONE: begin
                    ack_tgl   <= ~ack_tgl;
                    mem_state <= MEM_IDLE;
                end

                default: mem_state <= MEM_IDLE;
            endcase
        end
    end

endmodule
