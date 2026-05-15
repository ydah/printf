#include <stdio.h>

#define TAPE_SIZE 30000
#if defined(__GNUC__) || defined(__clang__)
#define PF_MAYBE_UNUSED __attribute__((unused))
#else
#define PF_MAYBE_UNUSED
#endif

typedef struct {
    unsigned short lo;
    unsigned short hi;
} PFCell32;

static inline void PF_MAYBE_UNUSED pf_set_cell(FILE *pf_sink, unsigned char *cell, int value) {
    int pad = value % 256;
    if (pad < 0) {
        pad += 256;
    }
    fprintf(pf_sink, "%1$.*2$d%3$hhn", 0, pad, (signed char *)cell);
}

static inline void PF_MAYBE_UNUSED pf_set_u32(FILE *pf_sink, unsigned int *dst, unsigned int value) {
    int pad = (int)(value & 2147483647u);
    fprintf(pf_sink, "%1$.*2$d%3$n", 0, pad, (int *)dst);
}

static inline void PF_MAYBE_UNUSED pf_add_cell(FILE *pf_sink, unsigned char *cell, int delta) {
    pf_set_cell(pf_sink, cell, (int)*cell + delta);
}

static inline void PF_MAYBE_UNUSED pf_inc_cell(FILE *pf_sink, unsigned char *cell) {
    fprintf(pf_sink, "%1$.*2$d %3$hhn", 0, (int)*cell, (signed char *)cell);
}

static inline void PF_MAYBE_UNUSED pf_dec_cell(FILE *pf_sink, unsigned char *cell) {
    fprintf(pf_sink, "%1$.*2$d%3$255d%4$hhn", 0, (int)*cell, 0, (signed char *)cell);
}

static inline void PF_MAYBE_UNUSED pf_clear_cell(FILE *pf_sink, unsigned char *cell) {
    pf_set_cell(pf_sink, cell, 0);
}

static inline void PF_MAYBE_UNUSED pf_add_cell_strict(FILE *pf_sink, unsigned char *cell, int delta) {
    int steps = delta % 256;
    if (steps < 0) {
        steps += 256;
    }

    if (steps <= 128) {
        while (steps > 0) {
            pf_inc_cell(pf_sink, cell);
            steps--;
        }
        return;
    }

    steps = 256 - steps;
    while (steps > 0) {
        pf_dec_cell(pf_sink, cell);
        steps--;
    }
}

static inline int PF_MAYBE_UNUSED pf_transfer_cell(FILE *pf_sink, unsigned char *tape, unsigned short dp, int offset, int scale) {
    int target = (int)dp + offset;
    if (target < 0 || target >= TAPE_SIZE) {
        fprintf(stderr, "pfc runtime error: transfer target out of range: %d\n", target);
        return 1;
    }

    pf_add_cell(pf_sink, &tape[target], (int)tape[dp] * scale);
    return 0;
}

static inline int PF_MAYBE_UNUSED pf_transfer_cell_strict(FILE *pf_sink, unsigned char *tape, unsigned short dp, int offset, int scale) {
    int target = (int)dp + offset;
    if (target < 0 || target >= TAPE_SIZE) {
        fprintf(stderr, "pfc runtime error: transfer target out of range: %d\n", target);
        return 1;
    }

    pf_add_cell_strict(pf_sink, &tape[target], (int)tape[dp] * scale);
    return 0;
}

static inline void PF_MAYBE_UNUSED pf_set_u16(FILE *pf_sink, unsigned short *dst, unsigned short value) {
    fprintf(pf_sink, "%1$.*2$d%3$hn", 0, (int)value, (short *)dst);
}

static inline void PF_MAYBE_UNUSED pf_add_cell16(FILE *pf_sink, unsigned short *cell, int delta) {
    pf_set_u16(pf_sink, cell, (unsigned short)((int)*cell + delta));
}

static inline void PF_MAYBE_UNUSED pf_inc_cell16(FILE *pf_sink, unsigned short *cell) {
    fprintf(pf_sink, "%1$.*2$d %3$hn", 0, (int)*cell, (short *)cell);
}

static inline void PF_MAYBE_UNUSED pf_dec_cell16(FILE *pf_sink, unsigned short *cell) {
    fprintf(pf_sink, "%1$.*2$d%3$65535d%4$hn", 0, (int)*cell, 0, (short *)cell);
}

static inline void PF_MAYBE_UNUSED pf_clear_cell16(FILE *pf_sink, unsigned short *cell) {
    pf_set_u16(pf_sink, cell, 0);
}

static inline void PF_MAYBE_UNUSED pf_add_cell16_strict(FILE *pf_sink, unsigned short *cell, int delta) {
    int steps = delta % 65536;
    if (steps < 0) {
        steps += 65536;
    }

    if (steps <= 32768) {
        while (steps > 0) {
            pf_inc_cell16(pf_sink, cell);
            steps--;
        }
        return;
    }

    steps = 65536 - steps;
    while (steps > 0) {
        pf_dec_cell16(pf_sink, cell);
        steps--;
    }
}

static inline int PF_MAYBE_UNUSED pf_transfer_cell16(FILE *pf_sink, unsigned short *tape, unsigned short dp, int offset, int scale) {
    int target = (int)dp + offset;
    if (target < 0 || target >= TAPE_SIZE) {
        fprintf(stderr, "pfc runtime error: transfer target out of range: %d\n", target);
        return 1;
    }

    pf_add_cell16(pf_sink, &tape[target], (int)tape[dp] * scale);
    return 0;
}

static inline int PF_MAYBE_UNUSED pf_transfer_cell16_strict(FILE *pf_sink, unsigned short *tape, unsigned short dp, int offset, int scale) {
    int target = (int)dp + offset;
    if (target < 0 || target >= TAPE_SIZE) {
        fprintf(stderr, "pfc runtime error: transfer target out of range: %d\n", target);
        return 1;
    }

    pf_add_cell16_strict(pf_sink, &tape[target], (int)tape[dp] * scale);
    return 0;
}

static inline unsigned int PF_MAYBE_UNUSED pf_cell32_value(const PFCell32 *cell) {
    return ((unsigned int)cell->hi << 16) | (unsigned int)cell->lo;
}

static inline void PF_MAYBE_UNUSED pf_set_cell32(FILE *pf_sink, PFCell32 *cell, unsigned int value) {
    pf_set_u16(pf_sink, &cell->lo, (unsigned short)(value & 65535u));
    pf_set_u16(pf_sink, &cell->hi, (unsigned short)(value >> 16));
}

static inline void PF_MAYBE_UNUSED pf_add_cell32(FILE *pf_sink, PFCell32 *cell, int delta) {
    pf_set_cell32(pf_sink, cell, pf_cell32_value(cell) + (unsigned int)delta);
}

static inline void PF_MAYBE_UNUSED pf_clear_cell32(FILE *pf_sink, PFCell32 *cell) {
    pf_set_cell32(pf_sink, cell, 0);
}

static inline void PF_MAYBE_UNUSED pf_inc_cell32(FILE *pf_sink, PFCell32 *cell) {
    if (cell->lo == 65535u) {
        pf_set_u16(pf_sink, &cell->lo, 0);
        pf_inc_cell16(pf_sink, &cell->hi);
        return;
    }

    pf_inc_cell16(pf_sink, &cell->lo);
}

static inline void PF_MAYBE_UNUSED pf_dec_cell32(FILE *pf_sink, PFCell32 *cell) {
    if (cell->lo == 0) {
        pf_set_u16(pf_sink, &cell->lo, 65535u);
        pf_dec_cell16(pf_sink, &cell->hi);
        return;
    }

    pf_dec_cell16(pf_sink, &cell->lo);
}

static inline void PF_MAYBE_UNUSED pf_add_cell32_strict(FILE *pf_sink, PFCell32 *cell, int delta) {
    unsigned int steps = (unsigned int)delta;
    if (steps <= 2147483648u) {
        while (steps > 0) {
            pf_inc_cell32(pf_sink, cell);
            steps--;
        }
        return;
    }

    steps = 0u - steps;
    while (steps > 0) {
        pf_dec_cell32(pf_sink, cell);
        steps--;
    }
}

static inline int PF_MAYBE_UNUSED pf_transfer_cell32(FILE *pf_sink, PFCell32 *tape, unsigned short dp, int offset, int scale) {
    int target = (int)dp + offset;
    if (target < 0 || target >= TAPE_SIZE) {
        fprintf(stderr, "pfc runtime error: transfer target out of range: %d\n", target);
        return 1;
    }

    pf_add_cell32(pf_sink, &tape[target], (int)(pf_cell32_value(&tape[dp]) * (unsigned int)scale));
    return 0;
}

static inline int PF_MAYBE_UNUSED pf_transfer_cell32_strict(FILE *pf_sink, PFCell32 *tape, unsigned short dp, int offset, int scale) {
    int target = (int)dp + offset;
    if (target < 0 || target >= TAPE_SIZE) {
        fprintf(stderr, "pfc runtime error: transfer target out of range: %d\n", target);
        return 1;
    }

    pf_add_cell32_strict(pf_sink, &tape[target], (int)(pf_cell32_value(&tape[dp]) * (unsigned int)scale));
    return 0;
}

static inline void PF_MAYBE_UNUSED pf_set_dp(FILE *pf_sink, unsigned short *dp, unsigned short value) {
    pf_set_u16(pf_sink, dp, value);
}

static inline void PF_MAYBE_UNUSED pf_set_opcode(FILE *pf_sink, unsigned char *opcode, int value) {
    pf_set_cell(pf_sink, opcode, value);
}

static inline void PF_MAYBE_UNUSED pf_advance_ip(FILE *pf_sink, unsigned int *ip) {
    pf_set_u32(pf_sink, ip, *ip + 1u);
}

static inline void PF_MAYBE_UNUSED pf_jump_ip(FILE *pf_sink, unsigned int *ip, unsigned int target) {
    pf_set_u32(pf_sink, ip, target);
}

static inline void PF_MAYBE_UNUSED pf_inc_dp(FILE *pf_sink, unsigned short *dp) {
    fprintf(pf_sink, "%1$.*2$d %3$hn", 0, (int)*dp, (short *)dp);
}

static inline void PF_MAYBE_UNUSED pf_dec_dp(FILE *pf_sink, unsigned short *dp) {
    fprintf(pf_sink, "%1$.*2$d%3$65535d%4$hn", 0, (int)*dp, 0, (short *)dp);
}

static inline int PF_MAYBE_UNUSED pf_move_ptr(FILE *pf_sink, unsigned short *dp, int delta) {
    int next = (int)*dp + delta;
    if (next < 0 || next >= TAPE_SIZE) {
        fprintf(stderr, "pfc runtime error: data pointer out of range: %d\n", next);
        return 1;
    }

    pf_set_dp(pf_sink, dp, (unsigned short)next);
    return 0;
}

static inline int PF_MAYBE_UNUSED pf_move_ptr_strict(FILE *pf_sink, unsigned short *dp, int delta) {
    int steps = delta;
    while (steps > 0) {
        if (*dp + 1 >= TAPE_SIZE) {
            fprintf(stderr, "pfc runtime error: data pointer out of range: %u\n", (unsigned)(*dp + 1));
            return 1;
        }
        pf_inc_dp(pf_sink, dp);
        steps--;
    }

    while (steps < 0) {
        if (*dp == 0) {
            fprintf(stderr, "pfc runtime error: data pointer out of range: -1\n");
            return 1;
        }
        pf_dec_dp(pf_sink, dp);
        steps++;
    }

    return 0;
}

static inline void PF_MAYBE_UNUSED pf_read_cell(FILE *pf_sink, unsigned char *cell) {
    int ch = getchar();
    if (ch == EOF) {
        ch = 0;
    }
    pf_set_cell(pf_sink, cell, ch);
}

static inline void PF_MAYBE_UNUSED pf_read_cell16(FILE *pf_sink, unsigned short *cell) {
    int ch = getchar();
    if (ch == EOF) {
        ch = 0;
    }
    pf_set_u16(pf_sink, cell, (unsigned short)ch);
}

static inline void PF_MAYBE_UNUSED pf_read_cell32(FILE *pf_sink, PFCell32 *cell) {
    int ch = getchar();
    if (ch == EOF) {
        ch = 0;
    }
    pf_set_cell32(pf_sink, cell, (unsigned int)ch);
}

static inline int PF_MAYBE_UNUSED pf_output_cell(unsigned char cell) {
    if (putchar((int)cell) == EOF) {
        perror("putchar");
        return 1;
    }
    return 0;
}

static inline int PF_MAYBE_UNUSED pf_output_counted_cell(unsigned char cell, int *count) {
    if (pf_output_cell(cell) != 0) {
        return 1;
    }
    *count += 1;
    return 0;
}

static inline int PF_MAYBE_UNUSED pf_output_counted_padding(int width, int *count) {
    while (width > 0) {
        if (pf_output_counted_cell((unsigned char)' ', count) != 0) {
            return 1;
        }
        width--;
    }
    return 0;
}

static inline int PF_MAYBE_UNUSED pf_output_u32_decimal(unsigned int value, int *count) {
    char digits[10];
    int length = 0;
    do {
        digits[length] = (char)('0' + (value % 10u));
        value /= 10u;
        length++;
    } while (value != 0u);

    while (length > 0) {
        length--;
        if (pf_output_counted_cell((unsigned char)digits[length], count) != 0) {
            return 1;
        }
    }

    return 0;
}

static inline int PF_MAYBE_UNUSED pf_output_i32_decimal(int value, int *count) {
    unsigned int magnitude;
    if (value < 0) {
        if (pf_output_counted_cell((unsigned char)'-', count) != 0) {
            return 1;
        }
        magnitude = 0u - (unsigned int)value;
    } else {
        magnitude = (unsigned int)value;
    }

    return pf_output_u32_decimal(magnitude, count);
}

static inline int PF_MAYBE_UNUSED pf_output_u64_decimal(unsigned long long value, int *count) {
    char digits[20];
    int length = 0;
    do {
        digits[length] = (char)('0' + (value % 10ull));
        value /= 10ull;
        length++;
    } while (value != 0ull);

    while (length > 0) {
        length--;
        if (pf_output_counted_cell((unsigned char)digits[length], count) != 0) {
            return 1;
        }
    }

    return 0;
}

static inline int PF_MAYBE_UNUSED pf_output_i64_decimal(long long value, int *count) {
    unsigned long long magnitude;
    if (value < 0) {
        if (pf_output_counted_cell((unsigned char)'-', count) != 0) {
            return 1;
        }
        magnitude = 0ull - (unsigned long long)value;
    } else {
        magnitude = (unsigned long long)value;
    }

    return pf_output_u64_decimal(magnitude, count);
}

static inline int PF_MAYBE_UNUSED pf_output_u32_radix(unsigned int value, unsigned int base, const char *digits, int *count) {
    char output[32];
    int length = 0;
    do {
        output[length] = digits[value % base];
        value /= base;
        length++;
    } while (value != 0u);

    while (length > 0) {
        length--;
        if (pf_output_counted_cell((unsigned char)output[length], count) != 0) {
            return 1;
        }
    }

    return 0;
}

static inline int PF_MAYBE_UNUSED pf_output_u64_radix(unsigned long long value, unsigned int base, const char *digits, int *count) {
    char output[64];
    int length = 0;
    do {
        output[length] = digits[value % base];
        value /= base;
        length++;
    } while (value != 0ull);

    while (length > 0) {
        length--;
        if (pf_output_counted_cell((unsigned char)output[length], count) != 0) {
            return 1;
        }
    }

    return 0;
}

static inline int PF_MAYBE_UNUSED pf_output_u64_formatted(unsigned long long value, unsigned int base, const char *digits, int width, int precision, int left_adjust, int zero_pad, int *count) {
    unsigned long long original = value;
    char output[64];
    int length = 0;
    int precision_padding;
    int content_width;
    int padding;

    do {
        output[length] = digits[value % base];
        value /= base;
        length++;
    } while (value != 0ull);

    if (precision == 0 && original == 0ull) {
        length = 0;
    }

    precision_padding = precision > length ? precision - length : 0;
    content_width = length + precision_padding;
    padding = width > content_width ? width - content_width : 0;
    if (zero_pad && !left_adjust && precision < 0) {
        precision_padding += padding;
        padding = 0;
    }

    if (!left_adjust && pf_output_counted_padding(padding, count) != 0) {
        return 1;
    }
    while (precision_padding > 0) {
        if (pf_output_counted_cell((unsigned char)'0', count) != 0) {
            return 1;
        }
        precision_padding--;
    }
    while (length > 0) {
        length--;
        if (pf_output_counted_cell((unsigned char)output[length], count) != 0) {
            return 1;
        }
    }
    if (left_adjust && pf_output_counted_padding(padding, count) != 0) {
        return 1;
    }
    return 0;
}

static inline int PF_MAYBE_UNUSED pf_output_i64_formatted(long long value, unsigned int base, const char *digits, int width, int precision, int left_adjust, int zero_pad, int *count) {
    int negative = value < 0;
    unsigned long long magnitude = negative ? 0ull - (unsigned long long)value : (unsigned long long)value;
    char output[64];
    int length = 0;
    int precision_padding;
    int content_width;
    int padding;

    do {
        output[length] = digits[magnitude % base];
        magnitude /= base;
        length++;
    } while (magnitude != 0ull);

    if (precision == 0 && !negative && value == 0) {
        length = 0;
    }

    precision_padding = precision > length ? precision - length : 0;
    content_width = length + precision_padding + negative;
    padding = width > content_width ? width - content_width : 0;
    if (zero_pad && !left_adjust && precision < 0) {
        precision_padding += padding;
        padding = 0;
    }

    if (!left_adjust && pf_output_counted_padding(padding, count) != 0) {
        return 1;
    }
    if (negative && pf_output_counted_cell((unsigned char)'-', count) != 0) {
        return 1;
    }
    while (precision_padding > 0) {
        if (pf_output_counted_cell((unsigned char)'0', count) != 0) {
            return 1;
        }
        precision_padding--;
    }
    while (length > 0) {
        length--;
        if (pf_output_counted_cell((unsigned char)output[length], count) != 0) {
            return 1;
        }
    }
    if (left_adjust && pf_output_counted_padding(padding, count) != 0) {
        return 1;
    }
    return 0;
}

static inline int PF_MAYBE_UNUSED pf_output_i64_signed_formatted(long long value, unsigned int base, const char *digits, int width, int precision, int left_adjust, int zero_pad, int sign_mode, int *count) {
    int negative = value < 0;
    unsigned char sign = 0u;
    unsigned long long magnitude = negative ? 0ull - (unsigned long long)value : (unsigned long long)value;
    char output[64];
    int length = 0;
    int precision_padding;
    int content_width;
    int padding;

    if (negative) {
        sign = (unsigned char)'-';
    } else if (sign_mode == 1) {
        sign = (unsigned char)'+';
    } else if (sign_mode == 2) {
        sign = (unsigned char)' ';
    }

    do {
        output[length] = digits[magnitude % base];
        magnitude /= base;
        length++;
    } while (magnitude != 0ull);

    if (precision == 0 && !negative && value == 0) {
        length = 0;
    }

    precision_padding = precision > length ? precision - length : 0;
    content_width = length + precision_padding + (sign != 0u);
    padding = width > content_width ? width - content_width : 0;
    if (zero_pad && !left_adjust && precision < 0) {
        precision_padding += padding;
        padding = 0;
    }

    if (!left_adjust && pf_output_counted_padding(padding, count) != 0) {
        return 1;
    }
    if (sign != 0u && pf_output_counted_cell(sign, count) != 0) {
        return 1;
    }
    while (precision_padding > 0) {
        if (pf_output_counted_cell((unsigned char)'0', count) != 0) {
            return 1;
        }
        precision_padding--;
    }
    while (length > 0) {
        length--;
        if (pf_output_counted_cell((unsigned char)output[length], count) != 0) {
            return 1;
        }
    }
    if (left_adjust && pf_output_counted_padding(padding, count) != 0) {
        return 1;
    }
    return 0;
}

static inline int PF_MAYBE_UNUSED pf_output_u64_prefixed_formatted(unsigned long long value, unsigned int base, const char *digits, int width, int precision, int left_adjust, int zero_pad, int prefix_mode, int *count) {
    unsigned long long original = value;
    const char *prefix = "";
    int prefix_length = 0;
    char output[64];
    int length = 0;
    int precision_padding;
    int content_width;
    int padding;

    do {
        output[length] = digits[value % base];
        value /= base;
        length++;
    } while (value != 0ull);

    if (precision == 0 && original == 0ull) {
        length = 0;
    }

    if ((prefix_mode == 1 && original != 0ull) || prefix_mode == 4) {
        prefix = "0x";
        prefix_length = 2;
    } else if (prefix_mode == 2 && original != 0ull) {
        prefix = "0X";
        prefix_length = 2;
    } else if (prefix_mode == 3 && (length == 0 || precision <= length)) {
        prefix = "0";
        prefix_length = 1;
    }

    precision_padding = precision > length ? precision - length : 0;
    content_width = length + precision_padding + prefix_length;
    padding = width > content_width ? width - content_width : 0;
    if (zero_pad && !left_adjust && precision < 0) {
        precision_padding += padding;
        padding = 0;
    }

    if (!left_adjust && pf_output_counted_padding(padding, count) != 0) {
        return 1;
    }
    while (prefix_length > 0) {
        if (pf_output_counted_cell((unsigned char)*prefix, count) != 0) {
            return 1;
        }
        prefix++;
        prefix_length--;
    }
    while (precision_padding > 0) {
        if (pf_output_counted_cell((unsigned char)'0', count) != 0) {
            return 1;
        }
        precision_padding--;
    }
    while (length > 0) {
        length--;
        if (pf_output_counted_cell((unsigned char)output[length], count) != 0) {
            return 1;
        }
    }
    if (left_adjust && pf_output_counted_padding(padding, count) != 0) {
        return 1;
    }
    return 0;
}

static inline int PF_MAYBE_UNUSED pf_output_cell16(unsigned short cell) {
    if (putchar((int)(cell & 255u)) == EOF) {
        perror("putchar");
        return 1;
    }
    return 0;
}

static inline int PF_MAYBE_UNUSED pf_output_cell32(PFCell32 cell) {
    if (putchar((int)(pf_cell32_value(&cell) & 255u)) == EOF) {
        perror("putchar");
        return 1;
    }
    return 0;
}

static inline void PF_MAYBE_UNUSED pf_llvm_store(unsigned char *memory, int index, unsigned long long value, int width) {
    int offset;
    for (offset = 0; offset < width; offset++) {
        memory[index + offset] = (unsigned char)((value >> (offset * 8)) & 255ull);
    }
}

static inline unsigned long long PF_MAYBE_UNUSED pf_llvm_load(const unsigned char *memory, int index, int width) {
    unsigned long long value = 0ull;
    int offset;
    for (offset = 0; offset < width; offset++) {
        value |= ((unsigned long long)memory[index + offset]) << (offset * 8);
    }
    return value;
}

static inline int PF_MAYBE_UNUSED pf_llvm_bytes_equal(const unsigned char *left, int left_index, const unsigned char *right, int right_index, int width) {
    int offset;
    for (offset = 0; offset < width; offset++) {
        if (left[left_index + offset] != right[right_index + offset]) return 0;
    }
    return 1;
}

static inline int PF_MAYBE_UNUSED pf_llvm_bytes_compare(const unsigned char *left, int left_index, const unsigned char *right, int right_index, int width) {
    int offset;
    for (offset = 0; offset < width; offset++) {
        unsigned char left_byte = left[left_index + offset];
        unsigned char right_byte = right[right_index + offset];
        if (left_byte != right_byte) return (int)left_byte - (int)right_byte;
    }
    return 0;
}

int main(void) {
    FILE *pf_sink = tmpfile();
    if (pf_sink == NULL) {
        perror("tmpfile");
        return 1;
    }

    enum { PF_LLVM_MEMORY_SIZE = 1 };
    enum { PF_LLVM_GLOBAL_MEMORY_SIZE = 1 };
    enum { PF_LLVM_STRING_MEMORY_SIZE = 1 };
    const unsigned long long PF_LLVM_GLOBAL_POINTER_TAG = 9223372036854775808ull;
    const unsigned long long PF_LLVM_READONLY_POINTER_TAG = 4611686018427387904ull;
    const unsigned long long PF_LLVM_STRING_POINTER_TAG = 2305843009213693952ull;
    const unsigned long long PF_LLVM_POINTER_OFFSET_MASK = 2305843009213693951ull;
    unsigned char llvm_memory[PF_LLVM_MEMORY_SIZE] = {0};
    unsigned char llvm_global_memory[PF_LLVM_GLOBAL_MEMORY_SIZE] = {0u};
    const unsigned char llvm_string_memory[PF_LLVM_STRING_MEMORY_SIZE] = {0u};
    int pf_return_code = 0;
    int pf_slot_index = 0;
    int pf_ch = 0;
    (void)llvm_memory;
    (void)llvm_global_memory;
    (void)llvm_string_memory;
    (void)pf_slot_index;
    (void)pf_ch;

    #define PF_ABORT() do { fclose(pf_sink); return 1; } while (0)
    goto pf_block_entry;

pf_block_entry:
    (void)0;
    pf_return_code = (int)(0);
    goto pf_done;

pf_done:
    #undef PF_ABORT
    if (fclose(pf_sink) != 0) {
        perror("fclose");
        return 1;
    }
    return pf_return_code;
}
