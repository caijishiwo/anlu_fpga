/*
 *  PicoSoC - A simple example SoC using PicoRV32
 *
 *  Copyright (C) 2017  Clifford Wolf <clifford@clifford.at>
 *
 *  Permission to use, copy, modify, and/or distribute this software for any
 *  purpose with or without fee is hereby granted, provided that the above
 *  copyright notice and this permission notice appear in all copies.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 *  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 *  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 *  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 *  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 *  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 *  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 */

// ============================================================================
// riscv_soc —— 合并进媒体工程 top.v 的 RISC-V 软核包装（M1）
//
//   与独立子工程 riscv\ 的区别：不含 PLL、不含 SDRAM 通路。
//     - 时钟 clk：top.v 里 sys_pll 的第二个实例给 50MHz
//     - 复位：沿用媒体工程的 rst_all（高有效异步复位）
//     - iomem_*：暴露给 top.v。M1 先接地（软核只用片上 ROM 4KB / RAM 16KB）；
//       M2 加 SDRAM 仲裁器后再接过去
//   入口 ROM 0x20000，栈顶 0x4000。
// ============================================================================

module riscv_soc (
    input  wire        clk,           // 软核时钟 50MHz
    input  wire        rst_all,       // 高有效异步复位
    output wire        ser_tx,
    input  wire        ser_rx,
    output wire        run_led,

    output wire        iomem_valid,
    output wire        iomem_instr,
    output wire [ 3:0] iomem_wstrb,
    output wire [31:0] iomem_addr,
    output wire [31:0] iomem_wdata,
    input  wire        iomem_ready,
    input  wire [31:0] iomem_rdata
);

    localparam integer LED_BIT = 26;

    wire resetn = ~rst_all;

    // 心跳灯：50MHz 下 bit26 每 2^26 拍翻转，约 1.34s
    reg [31:0] run_led_r = 32'd0;
    always @(posedge clk or posedge rst_all) begin
        if (rst_all)
            run_led_r <= 32'd0;
        else
            run_led_r <= run_led_r + 32'd1;
    end
    assign run_led = run_led_r[LED_BIT];

    picosoc32 soc (
        .clk         (clk         ),
        .resetn      (resetn      ),

        .ser_tx      (ser_tx      ),
        .ser_rx      (ser_rx      ),
        .ex_irq      (24'd0       ),

        .iomem_valid (iomem_valid ),
        .iomem_instr (iomem_instr ),
        .iomem_ready (iomem_ready ),
        .iomem_wstrb (iomem_wstrb ),
        .iomem_addr  (iomem_addr  ),
        .iomem_wdata (iomem_wdata ),
        .iomem_rdata (iomem_rdata )
    );

endmodule


module pico_ram #(
    parameter integer WORDS = 2048
) (
    input         valid,
    input         clk,
    input  [3:0]  wen,
    input  [13:0] addr,
    input  [31:0] wdata,
    output reg    ready,
    output [31:0] rdata
);

    soc_mem mem (
        .rsta (1'b0              ),
        .addra(addr[10:0]        ),
        .wea  (valid ? wen : 4'b0),
        .clka (clk               ),
        .dia  (wdata             ),
        .doa  (rdata             )
    );

    initial ready = 1'b0;

    always @(posedge clk)
        ready <= valid && !ready;

endmodule


module pico_rom #(
    parameter integer WORDS = 4096
) (
    input         valid,
    input         clk,
    input  [3:0]  wen,
    input  [14:0] addr,
    input  [31:0] wdata,
    output reg    ready,
    output [31:0] rdata
);

    rom picrv_rom (
        .rsta (1'b0     ),
        .addra(addr[7:0]),
        .clka (clk      ),
        .doa  (rdata    )
    );

    initial ready = 1'b0;

    always @(posedge clk)
        ready <= valid && !ready;

endmodule
