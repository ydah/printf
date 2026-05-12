# frozen_string_literal: true

require_relative "../ir"
require_relative "printf_primitives"

module PFC
  module Backend
    class ThreadedCEmitter
      DEFAULT_TAPE_SIZE = 30_000
      MAX_PROGRAM_LENGTH = 65_535

      FlatInstruction = Struct.new(:opcode, :operand, :operand2, keyword_init: true)

      def initialize(tape_size: DEFAULT_TAPE_SIZE, strict_printf: false)
        @tape_size = Integer(tape_size)
        @strict_printf = strict_printf
        validate_tape_size!
      end

      def emit(program)
        flat_program = flatten(program.instructions)
        validate_program_length!(flat_program)

        lines = []
        lines << "#include <stddef.h>"
        lines << "#include <stdio.h>"
        lines << ""
        lines << PrintfPrimitives.source(tape_size: tape_size).rstrip
        lines << ""
        lines.concat(type_definitions)
        lines << ""
        lines.concat(program_table(flat_program))
        lines << ""
        lines.concat(main_function)
        "#{lines.join("\n")}\n"
      end

      private

      attr_reader :tape_size

      def strict_printf?
        @strict_printf
      end

      def validate_tape_size!
        return if tape_size.between?(1, 65_535)

        raise ArgumentError, "tape size must be between 1 and 65535"
      end

      def validate_program_length!(flat_program)
        return if flat_program.length <= MAX_PROGRAM_LENGTH

        raise ArgumentError, "threaded program too large: #{flat_program.length} instructions"
      end

      def flatten(instructions)
        output = []
        flatten_into(instructions, output)
        output << FlatInstruction.new(opcode: "PF_OP_HALT", operand: 0, operand2: 0)
        output
      end

      def flatten_into(instructions, output)
        instructions.each do |instruction|
          case instruction
          when IR::AddCell
            output << FlatInstruction.new(opcode: "PF_OP_ADD", operand: instruction.delta, operand2: 0)
          when IR::MovePtr
            output << FlatInstruction.new(opcode: "PF_OP_MOVE", operand: instruction.delta, operand2: 0)
          when IR::OutputCell
            output << FlatInstruction.new(opcode: "PF_OP_OUTPUT", operand: 0, operand2: 0)
          when IR::InputCell
            output << FlatInstruction.new(opcode: "PF_OP_INPUT", operand: 0, operand2: 0)
          when IR::ClearCell
            output << FlatInstruction.new(opcode: "PF_OP_CLEAR", operand: 0, operand2: 0)
          when IR::TransferCell
            flatten_transfer(instruction, output)
          when IR::Loop
            flatten_loop(instruction, output)
          else
            raise ArgumentError, "unknown IR instruction: #{instruction.inspect}"
          end
        end
      end

      def flatten_loop(loop, output)
        start_index = output.length
        output << FlatInstruction.new(opcode: "PF_OP_JZ", operand: 0, operand2: 0)
        flatten_into(loop.body, output)
        output << FlatInstruction.new(opcode: "PF_OP_JNZ", operand: start_index, operand2: 0)
        output[start_index].operand = output.length
      end

      def flatten_transfer(instruction, output)
        instruction.transfers.each do |offset, scale|
          output << FlatInstruction.new(opcode: "PF_OP_TRANSFER", operand: offset, operand2: scale)
        end
        output << FlatInstruction.new(opcode: "PF_OP_CLEAR", operand: 0, operand2: 0)
      end

      def type_definitions
        [
          "typedef enum {",
          "    PF_OP_ADD,",
          "    PF_OP_MOVE,",
          "    PF_OP_OUTPUT,",
          "    PF_OP_INPUT,",
          "    PF_OP_CLEAR,",
          "    PF_OP_TRANSFER,",
          "    PF_OP_JZ,",
          "    PF_OP_JNZ,",
          "    PF_OP_HALT",
          "} PFOpcode;",
          "",
          "typedef struct {",
          "    unsigned char opcode;",
          "    int operand;",
          "    int operand2;",
          "} PFInstruction;"
        ]
      end

      def program_table(flat_program)
        lines = ["static const PFInstruction pf_program[] = {"]
        flat_program.each do |instruction|
          lines << "    {#{instruction.opcode}, #{instruction.operand}, #{instruction.operand2}},"
        end
        lines << "};"
        lines
      end

      def main_function
        [
          "int main(void) {",
          "    FILE *pf_sink = fopen(\"/dev/null\", \"w\");",
          "    if (pf_sink == NULL) {",
          "        perror(\"fopen\");",
          "        return 1;",
          "    }",
          "",
          "    unsigned char tape[TAPE_SIZE] = {0};",
          "    unsigned short dp = 0;",
          "    unsigned short ip = 0;",
          "    unsigned char opcode = 0;",
          "    const unsigned short program_len = (unsigned short)(sizeof(pf_program) / sizeof(pf_program[0]));",
          "",
          "    #define PF_ABORT() do { fclose(pf_sink); return 1; } while (0)",
          "    while (ip < program_len) {",
          "        const PFInstruction instruction = pf_program[ip];",
          "        pf_set_opcode(pf_sink, &opcode, instruction.opcode);",
          "",
          "        switch ((PFOpcode)opcode) {",
          "        case PF_OP_ADD:",
          add_cell_dispatch_line,
          "            pf_advance_ip(pf_sink, &ip);",
          "            break;",
          "        case PF_OP_MOVE:",
          "            if (#{move_ptr_helper}(pf_sink, &dp, instruction.operand) != 0) PF_ABORT();",
          "            pf_advance_ip(pf_sink, &ip);",
          "            break;",
          "        case PF_OP_OUTPUT:",
          "            if (pf_output_cell(tape[dp]) != 0) PF_ABORT();",
          "            pf_advance_ip(pf_sink, &ip);",
          "            break;",
          "        case PF_OP_INPUT:",
          "            pf_read_cell(pf_sink, &tape[dp]);",
          "            pf_advance_ip(pf_sink, &ip);",
          "            break;",
          "        case PF_OP_CLEAR:",
          "            pf_clear_cell(pf_sink, &tape[dp]);",
          "            pf_advance_ip(pf_sink, &ip);",
          "            break;",
          "        case PF_OP_TRANSFER:",
          "            if (#{transfer_cell_helper}(pf_sink, tape, dp, instruction.operand, instruction.operand2) != 0) PF_ABORT();",
          "            pf_advance_ip(pf_sink, &ip);",
          "            break;",
          "        case PF_OP_JZ:",
          "            if (tape[dp] == 0) {",
          "                pf_jump_ip(pf_sink, &ip, (unsigned short)instruction.operand);",
          "            } else {",
          "                pf_advance_ip(pf_sink, &ip);",
          "            }",
          "            break;",
          "        case PF_OP_JNZ:",
          "            if (tape[dp] != 0) {",
          "                pf_jump_ip(pf_sink, &ip, (unsigned short)instruction.operand);",
          "            } else {",
          "                pf_advance_ip(pf_sink, &ip);",
          "            }",
          "            break;",
          "        case PF_OP_HALT:",
          "            goto pf_done;",
          "        }",
          "    }",
          "pf_done:",
          "    #undef PF_ABORT",
          "",
          "    if (fclose(pf_sink) != 0) {",
          "        perror(\"fclose\");",
          "        return 1;",
          "    }",
          "    return 0;",
          "}"
        ]
      end

      def add_cell_dispatch_line
        helper = strict_printf? ? "pf_add_cell_strict" : "pf_add_cell"
        "            #{helper}(pf_sink, &tape[dp], instruction.operand);"
      end

      def move_ptr_helper
        strict_printf? ? "pf_move_ptr_strict" : "pf_move_ptr"
      end

      def transfer_cell_helper
        strict_printf? ? "pf_transfer_cell_strict" : "pf_transfer_cell"
      end
    end
  end
end
