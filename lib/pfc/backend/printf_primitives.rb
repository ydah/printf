# frozen_string_literal: true

module PFC
  module Backend
    module PrintfPrimitives
      def self.source(tape_size:)
        <<~C
          #define TAPE_SIZE #{Integer(tape_size)}
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
                  fprintf(stderr, "pfc runtime error: transfer target out of range: %d\\n", target);
                  return 1;
              }

              pf_add_cell(pf_sink, &tape[target], (int)tape[dp] * scale);
              return 0;
          }

          static inline int PF_MAYBE_UNUSED pf_transfer_cell_strict(FILE *pf_sink, unsigned char *tape, unsigned short dp, int offset, int scale) {
              int target = (int)dp + offset;
              if (target < 0 || target >= TAPE_SIZE) {
                  fprintf(stderr, "pfc runtime error: transfer target out of range: %d\\n", target);
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
                  fprintf(stderr, "pfc runtime error: transfer target out of range: %d\\n", target);
                  return 1;
              }

              pf_add_cell16(pf_sink, &tape[target], (int)tape[dp] * scale);
              return 0;
          }

          static inline int PF_MAYBE_UNUSED pf_transfer_cell16_strict(FILE *pf_sink, unsigned short *tape, unsigned short dp, int offset, int scale) {
              int target = (int)dp + offset;
              if (target < 0 || target >= TAPE_SIZE) {
                  fprintf(stderr, "pfc runtime error: transfer target out of range: %d\\n", target);
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
                  fprintf(stderr, "pfc runtime error: transfer target out of range: %d\\n", target);
                  return 1;
              }

              pf_add_cell32(pf_sink, &tape[target], (int)(pf_cell32_value(&tape[dp]) * (unsigned int)scale));
              return 0;
          }

          static inline int PF_MAYBE_UNUSED pf_transfer_cell32_strict(FILE *pf_sink, PFCell32 *tape, unsigned short dp, int offset, int scale) {
              int target = (int)dp + offset;
              if (target < 0 || target >= TAPE_SIZE) {
                  fprintf(stderr, "pfc runtime error: transfer target out of range: %d\\n", target);
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

          static inline void PF_MAYBE_UNUSED pf_advance_ip(FILE *pf_sink, unsigned short *ip) {
              pf_set_u16(pf_sink, ip, (unsigned short)(*ip + 1));
          }

          static inline void PF_MAYBE_UNUSED pf_jump_ip(FILE *pf_sink, unsigned short *ip, unsigned short target) {
              pf_set_u16(pf_sink, ip, target);
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
                  fprintf(stderr, "pfc runtime error: data pointer out of range: %d\\n", next);
                  return 1;
              }

              pf_set_dp(pf_sink, dp, (unsigned short)next);
              return 0;
          }

          static inline int PF_MAYBE_UNUSED pf_move_ptr_strict(FILE *pf_sink, unsigned short *dp, int delta) {
              int steps = delta;
              while (steps > 0) {
                  if (*dp + 1 >= TAPE_SIZE) {
                      fprintf(stderr, "pfc runtime error: data pointer out of range: %u\\n", (unsigned)(*dp + 1));
                      return 1;
                  }
                  pf_inc_dp(pf_sink, dp);
                  steps--;
              }

              while (steps < 0) {
                  if (*dp == 0) {
                      fprintf(stderr, "pfc runtime error: data pointer out of range: -1\\n");
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
        C
      end
    end
  end
end
