# frozen_string_literal: true

require_relative "../ir"
require_relative "printf_primitives"

module PFC
  module Backend
    class CEmitter
      DEFAULT_TAPE_SIZE = 30_000

      def initialize(tape_size: DEFAULT_TAPE_SIZE, strict_printf: false, cell_bits: 8)
        @tape_size = Integer(tape_size)
        @strict_printf = strict_printf
        @cell_bits = Integer(cell_bits)
        validate_tape_size!
        validate_cell_bits!
      end

      def emit(program)
        lines = []
        lines << "#include <stdio.h>"
        lines << ""
        lines << PrintfPrimitives.source(tape_size: tape_size).rstrip
        lines << ""
        lines << "int main(void) {"
        lines << "    FILE *pf_sink = tmpfile();"
        lines << "    if (pf_sink == NULL) {"
        lines << "        perror(\"tmpfile\");"
        lines << "        return 1;"
        lines << "    }"
        lines << ""
        lines << "    #{cell_type} tape[TAPE_SIZE] = {0};"
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

      attr_reader :cell_bits, :tape_size

      def strict_printf?
        @strict_printf
      end

      def validate_tape_size!
        return if tape_size.between?(1, 65_535)

        raise ArgumentError, "tape size must be between 1 and 65535"
      end

      def validate_cell_bits!
        return if [8, 16, 32].include?(cell_bits)

        raise ArgumentError, "cell bits must be 8, 16, or 32"
      end

      def emit_instructions(instructions, indent:)
        instructions.flat_map { |instruction| emit_instruction(instruction, indent:) }
      end

      def emit_instruction(instruction, indent:)
        spaces = "    " * indent

        case instruction
        when IR::AddCell
          emit_add_cell(instruction, spaces)
        when IR::MovePtr
          emit_move_ptr(instruction, spaces)
        when IR::OutputCell
          ["#{spaces}if (#{output_helper}(tape[dp]) != 0) PF_ABORT();"]
        when IR::InputCell
          ["#{spaces}#{read_helper}(pf_sink, &tape[dp]);"]
        when IR::ClearCell
          ["#{spaces}#{clear_helper}(pf_sink, &tape[dp]);"]
        when IR::SetCell
          emit_set_cell(instruction, spaces)
        when IR::TransferCell
          emit_transfer_cell(instruction, spaces)
        when IR::Loop
          emit_loop(instruction, indent:)
        else
          raise ArgumentError, "unknown IR instruction: #{instruction.inspect}"
        end
      end

      def emit_loop(loop, indent:)
        spaces = "    " * indent
        lines = ["#{spaces}while (#{cell_value_expr} != 0) {"]
        lines.concat(emit_instructions(loop.body, indent: indent + 1))
        lines << "#{spaces}}"
        lines
      end

      def emit_add_cell(instruction, spaces)
        return ["#{spaces}#{add_helper}(pf_sink, &tape[dp], #{instruction.delta});"] unless strict_printf?

        strict_cell_steps(instruction.delta).map do |step|
          helper = step.positive? ? inc_helper : dec_helper
          "#{spaces}#{helper}(pf_sink, &tape[dp]);"
        end
      end

      def emit_move_ptr(instruction, spaces)
        helper = strict_printf? ? "pf_move_ptr_strict" : "pf_move_ptr"
        ["#{spaces}if (#{helper}(pf_sink, &dp, #{instruction.delta}) != 0) PF_ABORT();"]
      end

      def emit_set_cell(instruction, spaces)
        return ["#{spaces}#{set_helper}(pf_sink, &tape[dp], #{instruction.value});"] unless strict_printf?

        ["#{spaces}#{clear_helper}(pf_sink, &tape[dp]);"] + strict_cell_steps(instruction.value).map do |step|
          helper = step.positive? ? inc_helper : dec_helper
          "#{spaces}#{helper}(pf_sink, &tape[dp]);"
        end
      end

      def emit_transfer_cell(instruction, spaces)
        helper = transfer_helper
        lines = instruction.transfers.map do |offset, scale|
          "#{spaces}if (#{helper}(pf_sink, tape, dp, #{offset}, #{scale}) != 0) PF_ABORT();"
        end
        lines << "#{spaces}#{clear_helper}(pf_sink, &tape[dp]);"
        lines
      end

      def strict_cell_steps(delta)
        modulus = 1 << cell_bits
        half = modulus / 2
        normalized = delta % modulus
        return [] if normalized.zero?

        if normalized <= half
          Array.new(normalized, 1)
        else
          Array.new(modulus - normalized, -1)
        end
      end

      def cell_type
        case cell_bits
        when 16 then "unsigned short"
        when 32 then "PFCell32"
        else "unsigned char"
        end
      end

      def add_helper
        return "pf_add_cell32" if cell_bits == 32
        cell_bits == 16 ? "pf_add_cell16" : "pf_add_cell"
      end

      def set_helper
        return "pf_set_cell32" if cell_bits == 32
        cell_bits == 16 ? "pf_set_u16" : "pf_set_cell"
      end

      def inc_helper
        return "pf_inc_cell32" if cell_bits == 32
        cell_bits == 16 ? "pf_inc_cell16" : "pf_inc_cell"
      end

      def dec_helper
        return "pf_dec_cell32" if cell_bits == 32
        cell_bits == 16 ? "pf_dec_cell16" : "pf_dec_cell"
      end

      def clear_helper
        return "pf_clear_cell32" if cell_bits == 32
        cell_bits == 16 ? "pf_clear_cell16" : "pf_clear_cell"
      end

      def read_helper
        return "pf_read_cell32" if cell_bits == 32
        cell_bits == 16 ? "pf_read_cell16" : "pf_read_cell"
      end

      def output_helper
        return "pf_output_cell32" if cell_bits == 32
        cell_bits == 16 ? "pf_output_cell16" : "pf_output_cell"
      end

      def transfer_helper
        return "pf_transfer_cell32_strict" if cell_bits == 32 && strict_printf?
        return "pf_transfer_cell32" if cell_bits == 32
        return "pf_transfer_cell16_strict" if cell_bits == 16 && strict_printf?
        return "pf_transfer_cell16" if cell_bits == 16
        return "pf_transfer_cell_strict" if strict_printf?

        "pf_transfer_cell"
      end

      def cell_value_expr
        cell_bits == 32 ? "pf_cell32_value(&tape[dp])" : "tape[dp]"
      end
    end
  end
end
