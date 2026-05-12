# frozen_string_literal: true

require_relative "../ir"
require_relative "printf_primitives"

module PFC
  module Backend
    class CEmitter
      DEFAULT_TAPE_SIZE = 30_000

      def initialize(tape_size: DEFAULT_TAPE_SIZE)
        @tape_size = Integer(tape_size)
        validate_tape_size!
      end

      def emit(program)
        lines = []
        lines << "#include <stdio.h>"
        lines << ""
        lines << PrintfPrimitives.source(tape_size: tape_size).rstrip
        lines << ""
        lines << "int main(void) {"
        lines << "    FILE *pf_sink = fopen(\"/dev/null\", \"w\");"
        lines << "    if (pf_sink == NULL) {"
        lines << "        perror(\"fopen\");"
        lines << "        return 1;"
        lines << "    }"
        lines << ""
        lines << "    unsigned char tape[TAPE_SIZE] = {0};"
        lines << "    unsigned short dp = 0;"
        lines << ""
        lines << "    #define PF_ABORT() do { fclose(pf_sink); return 1; } while (0)"
        lines.concat(emit_instructions(program.instructions, indent: 1))
        lines << "    #undef PF_ABORT"
        lines << ""
        lines << "    if (fclose(pf_sink) != 0) {"
        lines << "        perror(\"fclose\");"
        lines << "        return 1;"
        lines << "    }"
        lines << "    return 0;"
        lines << "}"
        "#{lines.join("\n")}\n"
      end

      private

      attr_reader :tape_size

      def validate_tape_size!
        return if tape_size.between?(1, 65_535)

        raise ArgumentError, "tape size must be between 1 and 65535"
      end

      def emit_instructions(instructions, indent:)
        instructions.flat_map { |instruction| emit_instruction(instruction, indent:) }
      end

      def emit_instruction(instruction, indent:)
        spaces = "    " * indent

        case instruction
        when IR::AddCell
          ["#{spaces}pf_add_cell(pf_sink, &tape[dp], #{instruction.delta});"]
        when IR::MovePtr
          ["#{spaces}if (pf_move_ptr(pf_sink, &dp, #{instruction.delta}) != 0) PF_ABORT();"]
        when IR::OutputCell
          ["#{spaces}if (pf_output_cell(tape[dp]) != 0) PF_ABORT();"]
        when IR::InputCell
          ["#{spaces}pf_read_cell(pf_sink, &tape[dp]);"]
        when IR::ClearCell
          ["#{spaces}pf_clear_cell(pf_sink, &tape[dp]);"]
        when IR::Loop
          emit_loop(instruction, indent:)
        else
          raise ArgumentError, "unknown IR instruction: #{instruction.inspect}"
        end
      end

      def emit_loop(loop, indent:)
        spaces = "    " * indent
        lines = ["#{spaces}while (tape[dp] != 0) {"]
        lines.concat(emit_instructions(loop.body, indent: indent + 1))
        lines << "#{spaces}}"
        lines
      end
    end
  end
end
