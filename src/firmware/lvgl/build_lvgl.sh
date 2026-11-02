#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
FW="$ROOT/src/firmware"
OUT="$FW/build"
LVGL="$OUT/lvgl-9.6.0"
OBJ="$OUT/lvgl_obj"
CC=riscv64-unknown-elf-gcc
OBJCOPY=riscv64-unknown-elf-objcopy
CFLAGS=(-march=rv32ic -mabi=ilp32 -std=gnu11 -Os -ffreestanding
        -fno-builtin -ffunction-sections -fdata-sections -fno-unwind-tables
        -DLV_CONF_INCLUDE_SIMPLE
        -I/usr/lib/picolibc/riscv64-unknown-elf/include
        -I"$FW/lvgl" -I"$LVGL")
MODE="${1:-release}"
APP_STEM=lvgl
OUTPUT_NAME=LVGL.BIN
case "$MODE" in
    release) ;;
    key-diagnostics)
        CFLAGS+=(-DAPP_KEY_DIAGNOSTICS=1)
        APP_STEM=lvgl_key_diagnostics
        OUTPUT_NAME=LVGL_KEY_DIAG.BIN
        ;;
    *) echo "Unknown build mode: $MODE (release or key-diagnostics)" >&2; exit 2 ;;
esac

mkdir -p "$OUT" "$OBJ"
if [[ ! -f "$LVGL/lvgl.h" ]]; then
    tar -xf "$FW/vendor/lvgl-9.6.0-core.tar.gz" -C "$OUT"
fi

cd "$ROOT"
python3 tools/patch_lvgl_i1.py
compile_source() {
    local source="$1"
    local relative="${source#"$LVGL/src/"}"
    local target="$OBJ/${relative%.c}.o"
    if [[ -f "$target" && "$target" -nt "$source" &&
          "$target" -nt "$FW/lvgl/lv_conf.h" ]]; then
        return
    fi
    mkdir -p "$(dirname "$target")"
    "$CC" "${CFLAGS[@]}" -c "$source" -o "$target"
}

pids=()
while IFS= read -r source; do
    compile_source "$source" &
    pids+=("$!")
    if (("${#pids[@]}" == 8)); then
        wait "${pids[0]}"
        pids=("${pids[@]:1}")
    fi
done < <(find "$LVGL/src" -name '*.c' \
    ! -path '*/drivers/*' ! -path '*/libs/*' ! -path '*/3d/*' | sort)
for pid in "${pids[@]}"; do
    wait "$pid"
done

for source in app_main.c app_music.c app_card.c app_settings.c settings_store.c music_catalog.c music_player.c ui_home.c ui_pages.c ui_font_chinese_20.c; do
    "$CC" "${CFLAGS[@]}" -c "$FW/lvgl/$source" -o "$OBJ/${source%.c}.o"
done
"$CC" -march=rv32ic -mabi=ilp32 -c "$FW/start.S" -o "$OBJ/start.o"

find "$OBJ" -name '*.o' -print | sort > "$OUT/lvgl_objects.txt"
"$CC" -march=rv32ic -mabi=ilp32 -nostdlib \
    -Wl,--gc-sections,-T,"$FW/lvgl/app_link.ld" \
    @"$OUT/lvgl_objects.txt" \
    /usr/lib/picolibc/riscv64-unknown-elf/lib/rv32i/ilp32/libc.a \
    -lgcc -o "$OUT/$APP_STEM.elf"
"$OBJCOPY" -O binary "$OUT/$APP_STEM.elf" "$OUT/$APP_STEM.bin"

python3 - "$OUT/$APP_STEM.bin" "$OUT/$OUTPUT_NAME" <<'PY'
from pathlib import Path
import struct
import sys

MAGIC = 0x4C47564C
LOAD_ADDRESS = 0x04258000
LIMIT_ADDRESS = 0x04350000
SECTOR_BYTES = 512
HASH_SEED = 2166136261
HASH_PRIME = 16777619

payload = Path(sys.argv[1]).read_bytes()
if not payload or len(payload) > LIMIT_ADDRESS - LOAD_ADDRESS:
    raise SystemExit(f"LVGL payload exceeds SDRAM application region: {len(payload)}")
checksum = HASH_SEED
for value in payload:
    checksum = ((checksum ^ value) * HASH_PRIME) & 0xFFFFFFFF
header = struct.pack("<4I", MAGIC, len(payload), checksum, LOAD_ADDRESS)
padding = (-len(payload)) % SECTOR_BYTES
Path(sys.argv[2]).write_bytes(header.ljust(SECTOR_BYTES, b"\0") +
                              payload + bytes(padding))
print(f"{Path(sys.argv[2]).name}: payload={len(payload)}, file={SECTOR_BYTES + len(payload) + padding}")
PY

riscv64-unknown-elf-size "$OUT/$APP_STEM.elf"
echo "Copy $OUT/$OUTPUT_NAME to the root of a FAT SD card as LVGL.BIN ($MODE)"
