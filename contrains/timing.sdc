# ============================================================================
# 时序约束  (2026-09-22 修订)
#
# 依据 anlu_fpga_Runs/phy_1/final_timing.rpt (2026-09-13 10:41):
#   修订前 Setup WNS -6.565ns / TNS -1325.868ns / 852 个违例端点
# 24 个 path group 里只有 1 个是真实的同域违例（100MHz 自环，491 端点），
# 其余 8 个组的 361 个端点都是「三个独立 PLL 被当成同步时钟分析」的伪违例。
#
# 刻意不使用 get_clocks * —— 本工具的通配不匹配，一旦写入会让整份 sdc
# 读取失败（已实测），所有时钟都用显式全名引用。
# ============================================================================

create_clock -name clk -period 20.000 -waveform {0.000 10.000} [get_ports {clk}]
derive_clocks

# --- 1) 时钟不确定度：故意不做任何设置 -----------------------------------------
# 实测本工具里 set_clock_uncertainty -hold 0.050 是「在默认 0.100ns 之上叠加」，
# 报告会显示 total 0.150ns，等于凭空多给 hold 加 50ps 余量，会把原本 Hold WNS
# +3ps（0 违规）压成 -62ps（32 违规）。基线本身没有 hold 问题，因此保持默认。

# --- 2) 异步复位不做时序分析 --------------------------------------------------
set_false_path -from [get_ports {rst_n}]

# --- 3) SDRAM 同源时钟必须进行时序分析 ---------------------------------------
# mem_clk 与 mem_clk_sft 同为 62.5 MHz，相位差 225°（10 ns）。
# 读写 I/O 路径不能因存在违例而整组声明为异步假路径。

# --- 4) 跨 PLL 异步时钟对 -----------------------------------------------------
# 三个 PLL 各自独立，与 50MHz 输入之间没有可分析的相位关系。跨域传输由同步
# 逻辑承担：u_audio_fifo(rfifo 写 sd_clk / 读 audio_mclk)、frame_read_write 的
# write_finish_toggle 打拍、I2S_receiver 用 25MHz 过采样音频域 BCLK、按键消抖等。
# 不声明的话工具会把这 361 个端点按同步路径分析。
# ★ 注意：本组约束只表示「不做同步时序分析」，不改变 RTL。上板前的 CDC 正确性
#   仍需逐条核对（见工程状态文档的待办）。

# clk(50MHz) <-> sys_pll
set_false_path -from [get_clocks {clk}] -to [get_clocks {u_sys_pll/pll_inst.clkc[0]}]
set_false_path -from [get_clocks {u_sys_pll/pll_inst.clkc[0]}] -to [get_clocks {clk}]
set_false_path -from [get_clocks {clk}] -to [get_clocks {u_sys_pll/pll_inst.clkc[1]}]
set_false_path -from [get_clocks {u_sys_pll/pll_inst.clkc[1]}] -to [get_clocks {clk}]
set_false_path -from [get_clocks {clk}] -to [get_clocks {u_sys_pll/pll_inst.clkc[2]}]
set_false_path -from [get_clocks {u_sys_pll/pll_inst.clkc[2]}] -to [get_clocks {clk}]

# clk(50MHz) <-> video_pll
set_false_path -from [get_clocks {clk}] -to [get_clocks {u_video_pll/pll_inst.clkc[0]}]
set_false_path -from [get_clocks {u_video_pll/pll_inst.clkc[0]}] -to [get_clocks {clk}]
set_false_path -from [get_clocks {clk}] -to [get_clocks {u_video_pll/pll_inst.clkc[1]}]
set_false_path -from [get_clocks {u_video_pll/pll_inst.clkc[1]}] -to [get_clocks {clk}]

# clk(50MHz) <-> audio_pll
set_false_path -from [get_clocks {clk}] -to [get_clocks {u_audio_pll/pll_inst.clkc[2]}]
set_false_path -from [get_clocks {u_audio_pll/pll_inst.clkc[2]}] -to [get_clocks {clk}]

# sys_pll <-> video_pll
set_false_path -from [get_clocks {u_sys_pll/pll_inst.clkc[0]}] -to [get_clocks {u_video_pll/pll_inst.clkc[0]}]
set_false_path -from [get_clocks {u_video_pll/pll_inst.clkc[0]}] -to [get_clocks {u_sys_pll/pll_inst.clkc[0]}]
set_false_path -from [get_clocks {u_sys_pll/pll_inst.clkc[0]}] -to [get_clocks {u_video_pll/pll_inst.clkc[1]}]
set_false_path -from [get_clocks {u_video_pll/pll_inst.clkc[1]}] -to [get_clocks {u_sys_pll/pll_inst.clkc[0]}]
set_false_path -from [get_clocks {u_sys_pll/pll_inst.clkc[1]}] -to [get_clocks {u_video_pll/pll_inst.clkc[0]}]
set_false_path -from [get_clocks {u_video_pll/pll_inst.clkc[0]}] -to [get_clocks {u_sys_pll/pll_inst.clkc[1]}]
set_false_path -from [get_clocks {u_sys_pll/pll_inst.clkc[1]}] -to [get_clocks {u_video_pll/pll_inst.clkc[1]}]
set_false_path -from [get_clocks {u_video_pll/pll_inst.clkc[1]}] -to [get_clocks {u_sys_pll/pll_inst.clkc[1]}]
set_false_path -from [get_clocks {u_sys_pll/pll_inst.clkc[2]}] -to [get_clocks {u_video_pll/pll_inst.clkc[0]}]
set_false_path -from [get_clocks {u_video_pll/pll_inst.clkc[0]}] -to [get_clocks {u_sys_pll/pll_inst.clkc[2]}]
set_false_path -from [get_clocks {u_sys_pll/pll_inst.clkc[2]}] -to [get_clocks {u_video_pll/pll_inst.clkc[1]}]
set_false_path -from [get_clocks {u_video_pll/pll_inst.clkc[1]}] -to [get_clocks {u_sys_pll/pll_inst.clkc[2]}]

# sys_pll <-> audio_pll
set_false_path -from [get_clocks {u_sys_pll/pll_inst.clkc[0]}] -to [get_clocks {u_audio_pll/pll_inst.clkc[2]}]
set_false_path -from [get_clocks {u_audio_pll/pll_inst.clkc[2]}] -to [get_clocks {u_sys_pll/pll_inst.clkc[0]}]
set_false_path -from [get_clocks {u_sys_pll/pll_inst.clkc[1]}] -to [get_clocks {u_audio_pll/pll_inst.clkc[2]}]
set_false_path -from [get_clocks {u_audio_pll/pll_inst.clkc[2]}] -to [get_clocks {u_sys_pll/pll_inst.clkc[1]}]
set_false_path -from [get_clocks {u_sys_pll/pll_inst.clkc[2]}] -to [get_clocks {u_audio_pll/pll_inst.clkc[2]}]
set_false_path -from [get_clocks {u_audio_pll/pll_inst.clkc[2]}] -to [get_clocks {u_sys_pll/pll_inst.clkc[2]}]

# video_pll <-> audio_pll
set_false_path -from [get_clocks {u_video_pll/pll_inst.clkc[0]}] -to [get_clocks {u_audio_pll/pll_inst.clkc[2]}]
set_false_path -from [get_clocks {u_audio_pll/pll_inst.clkc[2]}] -to [get_clocks {u_video_pll/pll_inst.clkc[0]}]
set_false_path -from [get_clocks {u_video_pll/pll_inst.clkc[1]}] -to [get_clocks {u_audio_pll/pll_inst.clkc[2]}]
set_false_path -from [get_clocks {u_audio_pll/pll_inst.clkc[2]}] -to [get_clocks {u_video_pll/pll_inst.clkc[1]}]
