# frozen_string_literal: true

require_relative "c_emitter"
require_relative "printf_primitives"

module PFC
  module Backend
    class LLVMCEmitter
      DEFAULT_TAPE_SIZE = CEmitter::DEFAULT_TAPE_SIZE
      NAME = /%[-A-Za-z$._0-9]+/
      VALUE = /-?\d+|%[-A-Za-z$._0-9]+/

      def initialize(source, tape_size: DEFAULT_TAPE_SIZE)
        @source = source
        @tape_size = Integer(tape_size)
        @blocks = parse_blocks(source)
        @slots = {}
        @slot_count = 0
        @pointers = {}
        @registers = {}
        validate_tape_size!
        analyze_allocations
        analyze_registers
      end

      def emit
        lines = []
        lines << "#include <stdio.h>"
        lines << ""
        lines << PrintfPrimitives.source(tape_size: tape_size).rstrip
        lines << ""
        lines << "int main(void) {"
        lines.concat(main_prelude)
        lines << "    goto #{c_label("entry")};"
        lines << ""
        block_order.each do |label|
          lines.concat(emit_block(label, blocks.fetch(label)))
        end
        lines.concat(main_epilogue)
        "#{lines.join("\n")}\n"
      end

      def dump_ir
        "LLVMSubsetCFG(blocks: #{block_order.join(', ')}, slots: #{slot_count}, registers: #{registers.keys.sort.join(', ')})"
      end

      private

      attr_reader :blocks, :block_order, :pointers, :registers, :slot_count, :source, :tape_size

      def validate_tape_size!
        return if tape_size.between?(1, 65_535)

        raise ArgumentError, "tape size must be between 1 and 65535"
      end

      def parse_blocks(source)
        body = extract_main_body(source)
        @block_order = ["entry"]
        parsed = { "entry" => [] }
        current = "entry"

        body.each_line do |line|
          stripped = line.sub(/;.*/, "").strip
          next if stripped.empty?

          if (match = stripped.match(/\A([-A-Za-z$._0-9]+):\z/))
            current = match[1]
            @block_order << current unless parsed.key?(current)
            parsed[current] ||= []
          else
            parsed[current] << stripped
          end
        end

        parsed
      end

      def extract_main_body(source)
        lines = source.each_line.to_a
        start = lines.index { |line| line.match?(/\A\s*define\s+(?:[-\w]+\s+)*i32\s+@main\s*\(/) }
        raise Frontend::LLVMSubset::ParseError, "missing define i32 @main()" if start.nil?

        body = []
        lines[(start + 1)..].each do |line|
          return body.join if line.strip == "}"

          body << line
        end

        raise Frontend::LLVMSubset::ParseError, "unterminated @main function"
      end

      def analyze_allocations
        all_lines.each do |line|
          if (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+\[(\d+)\s+x\s+i8\](?:,\s+align\s+\d+)?\z/))
            allocate_pointer(match[1], match[2].to_i)
          elsif (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+i(8|16|32)(?:,\s+align\s+\d+)?\z/))
            allocate_pointer(match[1], 1)
          end
        end
      end

      def analyze_registers
        all_lines.each do |line|
          lhs = line[/\A(#{NAME})\s*=/, 1]
          next if lhs.nil?
          next if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*alloca\b/)
          next if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*getelementptr\b/)

          registers[lhs] = c_value_name(lhs)
        end
      end

      def all_lines
        blocks.values.flatten
      end

      def allocate_pointer(name, width)
        return if @slots.key?(name)

        @slots[name] = slot_count
        pointers[name] = slot_count
        @slot_count += width
      end

      def main_prelude
        lines = [
          "    FILE *pf_sink = fopen(\"/dev/null\", \"w\");",
          "    if (pf_sink == NULL) {",
          "        perror(\"fopen\");",
          "        return 1;",
          "    }",
          "",
          "    unsigned char llvm_slots[#{[slot_count, 1].max}] = {0};",
          "    int pf_return_code = 0;",
          "    int pf_ch = 0;"
        ]
        registers.each_value do |name|
          lines << "    unsigned int #{name} = 0;"
        end
        lines << "    (void)llvm_slots;"
        lines << "    (void)pf_ch;"
        registers.each_value do |name|
          lines << "    (void)#{name};"
        end
        lines << ""
        lines << "    #define PF_ABORT() do { fclose(pf_sink); return 1; } while (0)"
        lines
      end

      def main_epilogue
        [
          "pf_done:",
          "    #undef PF_ABORT",
          "    if (fclose(pf_sink) != 0) {",
          "        perror(\"fclose\");",
          "        return 1;",
          "    }",
          "    return pf_return_code;",
          "}"
        ]
      end

      def emit_block(label, lines)
        output = ["#{c_label(label)}:"]
        body_lines(label, lines).each do |line|
          output.concat(emit_statement(label, line))
        end
        output << ""
        output
      end

      def body_lines(_label, lines)
        lines.reject { |line| phi?(line) }
      end

      def emit_statement(label, line)
        return emit_gep(line) if line.include?("getelementptr")
        return [] if alloca?(line)
        return emit_store(line) if line.start_with?("store ")
        return emit_load(line) if line.include?(" load ")
        return emit_binary(line) if line.match?(/\A#{NAME}\s*=\s*(add|sub)\b/)
        return emit_cast(line) if line.match?(/\A#{NAME}\s*=\s*(zext|sext|trunc)\b/)
        return emit_icmp(line) if line.match?(/\A#{NAME}\s*=\s*icmp\b/)
        return emit_call(line) if line.include?("call ")
        return emit_branch(label, line) if line.start_with?("br ")
        return emit_return(line) if line.start_with?("ret ")

        raise Frontend::LLVMSubset::ParseError, "unsupported LLVM instruction: #{line}"
      end

      def emit_gep(line)
        if (match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+inbounds)?\s+\[(\d+)\s+x\s+i8\],\s+ptr\s+(#{NAME}),\s+i\d+\s+0,\s+i\d+\s+(-?\d+)\z/))
          pointers[match[1]] = pointer_index(match[3]) + match[4].to_i
          return []
        end

        match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+inbounds)?\s+i8,\s+ptr\s+(#{NAME}),\s+i\d+\s+(-?\d+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported getelementptr: #{line}" unless match

        pointers[match[1]] = pointer_index(match[2]) + match[3].to_i
        []
      end

      def emit_store(line)
        match = line.match(/\Astore\s+i(8|16|32)\s+(.+?),\s+(?:ptr|i(?:8|16|32)\*)\s+(#{NAME})(?:,\s+align\s+\d+)?\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported store: #{line}" unless match

        value = llvm_value(match[2])
        ["    pf_set_cell(pf_sink, &llvm_slots[#{pointer_index(match[3])}], (int)(#{value}));"]
      end

      def emit_load(line)
        match = line.match(/\A(#{NAME})\s*=\s*load\s+i(8|16|32),\s+(?:ptr|i(?:8|16|32)\*)\s+(#{NAME})(?:,\s+align\s+\d+)?\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported load: #{line}" unless match

        ["    #{register(match[1])} = (unsigned int)llvm_slots[#{pointer_index(match[3])}];"]
      end

      def emit_binary(line)
        match = line.match(/\A(#{NAME})\s*=\s*(add|sub)\s+i(8|16|32)\s+(.+?),\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported binary op: #{line}" unless match

        operator = match[2] == "add" ? "+" : "-"
        mask = integer_mask(match[3].to_i)
        left = llvm_value(match[4])
        right = llvm_value(match[5])
        ["    #{register(match[1])} = (unsigned int)(((#{left}) #{operator} (#{right})) & #{mask}u);"]
      end

      def emit_cast(line)
        match = line.match(/\A(#{NAME})\s*=\s*(zext|sext|trunc)\s+i(1|8|16|32)\s+(.+?)\s+to\s+i(1|8|16|32)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported cast: #{line}" unless match

        value = llvm_value(match[4])
        bits = match[5].to_i
        ["    #{register(match[1])} = (unsigned int)((#{value}) & #{integer_mask(bits)}u);"]
      end

      def emit_icmp(line)
        match = line.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne)\s+i(8|16|32)\s+(.+?),\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported icmp: #{line}" unless match

        operator = match[2] == "eq" ? "==" : "!="
        left = llvm_value(match[4])
        right = llvm_value(match[5])
        ["    #{register(match[1])} = ((#{left}) #{operator} (#{right})) ? 1u : 0u;"]
      end

      def emit_call(line)
        if (match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@getchar\(\)\z/))
          output = ["    pf_ch = getchar();"]
          output << "    #{register(match[1])} = pf_ch == EOF ? 0u : (unsigned int)(unsigned char)pf_ch;" if match[1]
          return output
        end

        match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@putchar\(i32\s+(.+)\)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported call: #{line}" unless match

        output = ["    if (pf_output_cell((unsigned char)(#{llvm_value(match[2])})) != 0) PF_ABORT();"]
        output << "    #{register(match[1])} = 0u;" if match[1]
        output
      end

      def emit_branch(label, line)
        if (match = line.match(/\Abr\s+label\s+%([-A-Za-z$._0-9]+)\z/))
          return phi_goto(label, match[1])
        end

        match = line.match(/\Abr\s+i1\s+(.+?),\s+label\s+%([-A-Za-z$._0-9]+),\s+label\s+%([-A-Za-z$._0-9]+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported branch: #{line}" unless match

        true_label = match[2]
        false_label = match[3]
        lines = ["    if ((#{llvm_value(match[1])}) != 0u) {"]
        lines.concat(phi_goto(label, true_label, indent: 2))
        lines << "    } else {"
        lines.concat(phi_goto(label, false_label, indent: 2))
        lines << "    }"
        lines
      end

      def emit_return(line)
        match = line.match(/\Aret\s+i32\s+(.+)\z/)
        return ["    goto pf_done;"] unless match

        [
          "    pf_return_code = (int)(#{llvm_value(match[1])});",
          "    goto pf_done;"
        ]
      end

      def phi_goto(from_label, to_label, indent: 1)
        spaces = "    " * indent
        lines = phi_lines(to_label).filter_map do |line|
          phi_assignment(line, from_label, spaces)
        end
        lines << "#{spaces}goto #{c_label(to_label)};"
        lines
      end

      def phi_lines(label)
        blocks.fetch(label).select { |line| phi?(line) }
      end

      def phi_assignment(line, from_label, spaces)
        match = line.match(/\A(#{NAME})\s*=\s*phi\s+i(1|8|16|32)\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported phi: #{line}" unless match

        incoming = match[3].scan(/\[\s*(.+?)\s*,\s+%([-A-Za-z$._0-9]+)\s*\]/)
        value = incoming.find { |_value, label| label == from_label }&.first
        return nil if value.nil?

        "#{spaces}#{register(match[1])} = (unsigned int)(#{llvm_value(value)});"
      end

      def llvm_value(raw)
        tokens = raw.strip.split(/\s+/)
        token = tokens.last
        return token if token.match?(/\A-?\d+\z/)
        return register(token) if token.match?(/\A#{NAME}\z/)

        raise Frontend::LLVMSubset::ParseError, "unsupported value: #{raw}"
      end

      def pointer_index(name)
        pointers.fetch(name) { raise Frontend::LLVMSubset::ParseError, "unknown pointer: #{name}" }
      end

      def register(name)
        registers.fetch(name) { raise Frontend::LLVMSubset::ParseError, "unknown register: #{name}" }
      end

      def alloca?(line)
        line.match?(/\A#{NAME}\s*=\s*alloca\b/)
      end

      def phi?(line)
        line.match?(/\A#{NAME}\s*=\s*phi\b/)
      end

      def c_label(label)
        "pf_block_#{label.gsub(/[^A-Za-z0-9_]/, '_')}"
      end

      def c_value_name(name)
        "pf_v_#{name.delete_prefix('%').gsub(/[^A-Za-z0-9_]/, '_')}"
      end

      def integer_mask(bits)
        return 1 if bits == 1

        (1 << bits) - 1
      end
    end
  end
end
