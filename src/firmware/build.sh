#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FW="$ROOT/src/firmware"
# The ROM only loads and verifies the SDRAM application.
OUT="$FW/build"
CC=riscv64-unknown-elf-gcc
OBJCOPY=riscv64-unknown-elf-objcopy

mkdir -p "$OUT"
"$CC" -march=rv32ic -mabi=ilp32 -c "$FW/start.S" -o "$OUT/start.o"
"$CC" -march=rv32ic -mabi=ilp32 -Os -ffreestanding -fno-builtin \
    -ffunction-sections -fdata-sections -nostdlib \
    "$FW/main.c" "$OUT/start.o" \
    -Wl,--gc-sections,-T,"$FW/link.ld" -lgcc -o "$OUT/boot.elf"

"$OBJCOPY" -O binary "$OUT/boot.elf" "$OUT/boot.bin"
python3 - "$OUT/boot.bin" "$ROOT/rt-thread.hex" "$ROOT/src/riscv/rt-thread.hex" <<'PY'
import pathlib
import sys

image = pathlib.Path(sys.argv[1]).read_bytes()
rom_words = 256
if len(image) > rom_words * 4:
    raise SystemExit(f"ROM overflow: {len(image)} bytes > {rom_words * 4}")
image = image.ljust(rom_words * 4, b"\0")
words = (int.from_bytes(image[i:i + 4], "little") for i in range(0, len(image), 4))
hex_text = "".join(f"{word:08x}\n" for word in words)
for path in sys.argv[2:]:
    pathlib.Path(path).write_text(hex_text)
PY

riscv64-unknown-elf-size "$OUT/boot.elf"
echo "ROM image: $ROOT/rt-thread.hex"
