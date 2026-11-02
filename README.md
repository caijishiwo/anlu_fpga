# Anlogic FPGA 多媒体播放器

本工程以安路 `EG4S20BG256` FPGA 为目标器件，使用 Tang Dynasty（TD）工程 `anlu_fpga.al`。顶层模块为 `src/top.v`，集成 TF 卡图片读取、SDRAM 帧缓存、HDMI 640×480 视频输出、音频播放、歌词叠加，以及 RISC-V + LVGL 菜单。

## 目录

- `anlu_fpga.al`：TD 工程入口，目标器件与源文件清单以此文件为准。
- `src/top.v`：系统顶层；`src/hdmi/`、`src/video/`、`src/audio/`、`src/lyric/`、`src/sd/`、`src/sdram/`、`src/riscv/` 分别存放各功能 RTL。
- `src/firmware/`：RISC-V 启动程序、LVGL 应用和构建脚本。
- `al_ip/`：TD 生成的 PLL、SDRAM、FIFO、UART 等 IP。
- `contrains/pin.adc`、`contrains/timing.sdc`：管脚与时序约束。目录名在工程中确实拼写为 `contrains`。
- `card/`：随工程提供的 TF 卡示例文件；`tool/`：多媒体转换工具。
- `anlu_fpga_Runs/`、`log/`：TD 运行结果和日志；已有位流位于 `anlu_fpga_Runs/best_result/anlu_fpga.bit`。

## 构建与下载

1. 在 TD 中打开 `anlu_fpga.al`，核对目标为 `EG4 / EG4S20BG256`，顶层为 `top`。
2. 确认 RTL、`al_ip/` 中的 IP，以及 `contrains/` 下两个约束文件均已包含在工程中。
3. 修改 RTL、约束或 ROM 镜像后，重新运行综合、布局布线和位流生成，再下载**本次生成**的 `.bit`。已有 `best_result` 仅代表目录中保存的一次构建结果。

ROM 通过 `src/riscv/rom.v` 的 `$readmemh("rt-thread.hex", mem)` 初始化。修改启动程序时，可在 Bash 环境中运行 `src/firmware/build.sh`；脚本需要 `riscv64-unknown-elf-gcc` 和 `riscv64-unknown-elf-objcopy`，并将镜像写入工程根目录及 `src/riscv/` 下的 `rt-thread.hex`。

LVGL 应用构建入口为 `src/firmware/lvgl/build_lvgl.sh`，产物为 TF 卡根目录使用的 `LVGL.BIN`。该脚本还依赖 Python 3、Picolibc 交叉编译库和 `tools/patch_lvgl_i1.py`；**当前工程目录缺少这个 Python 文件，因此脚本不能直接完整运行**。目录中已提供 `card/LVGL.BIN` 示例文件。

## TF 卡内容

`card/` 仅包含部分示例文件，不是一张完整的媒体卡。将 `LVGL.BIN` 放在卡根目录；`SETTINGS.BIN` 也在示例卡根目录。音乐目录为 `MUSIC/`，歌词目录为 `LYRIC/`，图片目录为 `PICTURE/`。图片目录读取逻辑按 FAT32 实现；音乐目录扫描代码支持 FAT16/FAT32，但播放器中的音乐文件须是项目自定义的 `ANLUWAV1` 格式 `.BIN`，不是普通 `.WAV`。对应音频参数为 48 kHz、16 bit、双声道，文件数据须连续分配。歌词使用与曲目同名的 `.LYR` 文件；示例见 `card/LYRIC/QINGTIAN.LYR`。

## 板上接口与诊断

输入时钟为 50 MHz（`clk`）；`rst_n`、`key1`、`key2`、`key_flip` 为低有效按键。`pin.adc` 中标注 `key1` 切换图片、`key2` 控制自动播放、`key_flip` 切换画面上下翻转。工程还连接 HDMI、TF 卡 SPI、四个调试 LED、六位数码管和 UART；UART 约束标注为 115200 8N1。具体管脚以 `contrains/pin.adc` 为准。

如果下载后画面或按键状态异常，先核对目标器件、顶层、约束、是否重新生成位流，以及下载的 `.bit` 是否为最新构建结果。
