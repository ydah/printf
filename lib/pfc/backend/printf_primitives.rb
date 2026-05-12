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

          static inline void PF_MAYBE_UNUSED pf_set_cell(FILE *pf_sink, unsigned char *cell, int value) {
              int pad = value % 256;
              if (pad < 0) {
                  pad += 256;
              }
              fprintf(pf_sink, "%1$.*2$d%3$hhn", 0, pad, (signed char *)cell);
          }

          static inline void PF_MAYBE_UNUSED pf_add_cell(FILE *pf_sink, unsigned char *cell, int delta) {
              pf_set_cell(pf_sink, cell, (int)*cell + delta);
          }

          static inline void PF_MAYBE_UNUSED pf_clear_cell(FILE *pf_sink, unsigned char *cell) {
              pf_set_cell(pf_sink, cell, 0);
          }

          static inline void PF_MAYBE_UNUSED pf_set_dp(FILE *pf_sink, unsigned short *dp, unsigned short value) {
              fprintf(pf_sink, "%1$.*2$d%3$hn", 0, (int)value, (short *)dp);
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

          static inline void PF_MAYBE_UNUSED pf_read_cell(FILE *pf_sink, unsigned char *cell) {
              int ch = getchar();
              if (ch == EOF) {
                  ch = 0;
              }
              pf_set_cell(pf_sink, cell, ch);
          }

          static inline int PF_MAYBE_UNUSED pf_output_cell(unsigned char cell) {
              if (putchar((int)cell) == EOF) {
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
