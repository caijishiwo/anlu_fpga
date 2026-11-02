#include <stdint.h>

#define UI_FILE_STATUS (*(volatile uint32_t *)0x03000020u)
#define UI_FILE_SECTOR (*(volatile uint32_t *)0x03000024u)
#define UI_FILE_BYTES (*(volatile uint32_t *)0x03000028u)
#define SD_REQUEST (*(volatile uint32_t *)0x03002000u)
#define SD_STATUS (*(volatile uint32_t *)0x03002004u)
#define SD_DATA ((volatile uint32_t *)0x03002100u)
#define SDRAM_FRAME ((volatile uint32_t *)0x04000000u)
#define APP_ADDRESS 0x04258000u
#define APP_LIMIT 0x04350000u
#define SECTOR_BYTES 512u
#define SECTOR_WORDS (SECTOR_BYTES / 4u)
#define LVGL_MAGIC 0x4c47564cu
#define HASH_SEED 2166136261u
#define UART_DIVIDER (*(volatile uint32_t *)0x02000000u)
#define UART_DATA (*(volatile uint32_t *)0x02000008u)
#define CPU_HZ 25000000u
#define UART_BAUD 115200u

typedef struct {
    uint32_t byte_count;
    uint32_t checksum;
    uint32_t entry;
    uint32_t sector_count;
} app_header_t;

static void uart_text(const char *text)
{
    while (*text)
        UART_DATA = (uint8_t)*text++;
}

static void uart_hex(uint32_t value)
{
    for (uint32_t digit = 0; digit < 8u; digit++) {
        uint32_t nibble = value >> 28;
        UART_DATA = nibble < 10u ? '0' + nibble : 'A' + nibble - 10u;
        value <<= 4;
    }
}

static void show_error(uint32_t reason)
{
    uart_text("ERR ");
    uart_hex(reason);
    uart_text("\r\n");
    for (;;)
        __asm__ volatile ("wfi");
}

static void show_mismatch(uint32_t address, uint32_t expected, uint32_t actual)
{
    uart_text("ADDR "); uart_hex(address);
    uart_text(" EXPECT "); uart_hex(expected);
    uart_text(" ACTUAL "); uart_hex(actual);
    uart_text("\r\n");
    for (uint32_t sample = 0; sample < 4u; sample++) {
        uart_hex(*(volatile uint32_t *)address);
        uart_text("\r\n");
    }
    for (;;)
        __asm__ volatile ("wfi");
}

static uint32_t hash_word(uint32_t hash, uint32_t word, uint32_t count)
{
    for (uint32_t byte = 0; byte < count; byte++) {
        hash ^= (uint8_t)(word >> (byte * 8u));
        hash = (hash << 24) + (hash << 8) + (hash << 7) +
               (hash << 4) + (hash << 1) + hash;
    }
    return hash;
}

static void read_sector(uint32_t sector)
{
    SD_REQUEST = sector;
    uint32_t status;
    do {
        status = SD_STATUS;
    } while ((status & 3u) != 2u);
    if ((status & 4u) || (status >> 3) != SECTOR_BYTES)
        show_error(3u);
}

static app_header_t read_header(uint32_t first_sector, uint32_t file_bytes)
{
    read_sector(first_sector);
    uint32_t payload_bytes = SD_DATA[1];
    if (SD_DATA[0] != LVGL_MAGIC || payload_bytes == 0u ||
        payload_bytes > APP_LIMIT - APP_ADDRESS ||
        SD_DATA[3] != APP_ADDRESS)
        show_error(2u);
    uint32_t sectors = (payload_bytes + SECTOR_BYTES - 1u) / SECTOR_BYTES;
    if (file_bytes != (sectors + 1u) * SECTOR_BYTES)
        show_error(2u);
    app_header_t header = {payload_bytes, SD_DATA[2], SD_DATA[3], sectors};
    return header;
}

static void probe_sdram(uint32_t first_sector, app_header_t header)
{
    volatile uint32_t *memory = SDRAM_FRAME;
    uint32_t offsets[] = {
        0u,
        (APP_ADDRESS - (uint32_t)SDRAM_FRAME + (header.byte_count / 2u & ~3u)) / 4u,
        (APP_ADDRESS - (uint32_t)SDRAM_FRAME + ((header.byte_count - 1u) & ~3u)) / 4u
    };
    for (uint32_t index = 0; index < 3u; index++)
        memory[offsets[index]] = offsets[index] ^ 0xa55a3cc3u;
    read_sector(first_sector);
    for (uint32_t index = 0; index < 3u; index++) {
        uint32_t actual = memory[offsets[index]];
        uint32_t expected = offsets[index] ^ 0xa55a3cc3u;
        if (actual != expected)
            show_mismatch((uint32_t)&memory[offsets[index]], expected, actual);
    }
}

static void locate_mismatch(uint32_t first_sector, app_header_t header)
{
    volatile const uint32_t *source = (volatile uint32_t *)APP_ADDRESS;
    for (uint32_t sector = 0; sector < header.sector_count; sector++) {
        read_sector(first_sector + sector + 1u);
        for (uint32_t word = 0; word < SECTOR_WORDS; word++) {
            uint32_t index = sector * SECTOR_WORDS + word;
            uint32_t expected = SD_DATA[word];
            uint32_t actual = source[index];
            if (actual != expected)
                show_mismatch((uint32_t)&source[index], expected, actual);
        }
    }
    // 先前校验失败，但本轮逐字比对恢复一致：明确报告瞬态故障。
    show_error(7u);
}

static void copy_payload(uint32_t first_sector, app_header_t header)
{
    volatile uint32_t *destination = (volatile uint32_t *)APP_ADDRESS;
    for (uint32_t sector = 0; sector < header.sector_count; sector++) {
        read_sector(first_sector + sector + 1u);
        for (uint32_t word = 0; word < SECTOR_WORDS; word++) {
            uint32_t offset = sector * SECTOR_BYTES + word * 4u;
            uint32_t value = SD_DATA[word];
            destination[offset / 4u] = value;
        }
        for (uint32_t word = 0; word < SECTOR_WORDS; word++) {
            volatile uint32_t *target = &destination[sector * SECTOR_WORDS + word];
            uint32_t actual = *target;
            if (actual != SD_DATA[word])
                show_mismatch((uint32_t)target, SD_DATA[word], actual);
        }
    }
}

static uint32_t verify_payload(app_header_t header)
{
    volatile const uint32_t *source = (volatile const uint32_t *)APP_ADDRESS;
    uint32_t hash = HASH_SEED;
    for (uint32_t offset = 0; offset < header.byte_count; offset += 4u) {
        uint32_t remaining = header.byte_count - offset;
        hash = hash_word(hash, source[offset / 4u],
                         remaining < 4u ? remaining : 4u);
    }
    return hash;
}

int main(void)
{
    // simpleuart 每位持续 divider+2 个 CPU 时钟。
    UART_DIVIDER = CPU_HZ / UART_BAUD - 2u;
    uart_text("BOOT UART\r\n");
    uint32_t file_status;
    do {
        file_status = UI_FILE_STATUS;
    } while ((file_status & 3u) == 0u);
    if (!(file_status & 1u))
        show_error(1u);

    uint32_t first_sector = UI_FILE_SECTOR;
    app_header_t header = read_header(first_sector, UI_FILE_BYTES);
    uart_text("COPY\r\n");
    copy_payload(first_sector, header);
    uint32_t hash = verify_payload(header);
    uart_text("HASH "); uart_hex(hash);
    uart_text(" EXPECT "); uart_hex(header.checksum); uart_text("\r\n");
    if (hash != header.checksum) {
        if (verify_payload(header) != header.checksum)
            locate_mismatch(first_sector, header);
        show_error(7u);
    }

    uart_text("RUN LVGL\r\n");
    ((void (*)(void))header.entry)();
    show_error(6u);
}
