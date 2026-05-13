# frozen_string_literal: true

require_relative "c_emitter"
require_relative "printf_primitives"
require_relative "../frontend/llvm_subset"

module PFC
  module Backend
    class LLVMCEmitter
      DEFAULT_TAPE_SIZE = CEmitter::DEFAULT_TAPE_SIZE
      NAME = /%[-A-Za-z$._0-9]+/

      def initialize(source, tape_size: DEFAULT_TAPE_SIZE)
        @source = source
        @tape_size = Integer(tape_size)
        @internal_functions = parse_internal_functions(source)
        @blocks = parse_blocks(source)
        @slots = {}
        @slot_count = 0
        @pointers = {}
        @registers = {}
        @inline_call_index = 0
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

      attr_reader :blocks, :block_order, :internal_functions, :pointers, :registers, :slot_count, :source, :tape_size

      def validate_tape_size!
        return if tape_size.between?(1, 65_535)

        raise ArgumentError, "tape size must be between 1 and 65535"
      end

      def parse_blocks(source)
        body = extract_main_body(source)
        @block_order = ["entry"]
        parsed = { "entry" => [] }
        current = "entry"

        normalized_lines(body).each do |stripped|
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

      def parse_internal_functions(source)
        functions = {}
        lines = source.each_line.to_a
        index = 0

        while index < lines.length
          header = lines[index].strip
          match = header.match(/\Adefine\s+(?:[-\w]+\s+)*i32\s+@([-A-Za-z$._0-9]+)\((.*?)\)\s*\{\z/)
          unless match
            index += 1
            next
          end

          name = match[1]
          body = []
          index += 1
          while index < lines.length && lines[index].strip != "}"
            body << lines[index]
            index += 1
          end
          functions[name] = {
            params: parse_parameters(match[2]),
            lines: normalized_function_lines(body.join)
          } unless name == "main"
          index += 1
        end

        functions
      end

      def parse_parameters(raw)
        return [] if raw.strip.empty?

        raw.split(",").map do |parameter|
          match = parameter.strip.match(/\Ai(?:1|8|16|32)\s+(#{NAME})\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported function parameter: #{parameter}" unless match

          match[1]
        end
      end

      def normalized_function_lines(body)
        normalized_lines(body).reject do |line|
          line.empty? || line.match?(/\A[-A-Za-z$._0-9]+:\z/)
        end
      end

      def normalized_lines(body)
        source_lines = body.each_line.map { |line| line.sub(/;.*/, "").strip }
        lines = []
        index = 0

        while index < source_lines.length
          line = source_lines[index]
          if line.start_with?("switch ") && line.include?("[") && !line.include?("]")
            line = collect_switch_line(line, source_lines, index + 1)
            index += 1 until index >= source_lines.length || source_lines[index].include?("]")
          end
          lines << line.gsub(/\s+/, " ")
          index += 1
        end

        lines
      end

      def collect_switch_line(line, source_lines, start_index)
        combined = line.dup
        index = start_index
        while index < source_lines.length
          combined << " #{source_lines[index]}"
          break if source_lines[index].include?("]")

          index += 1
        end
        combined
      end

      def extract_main_body(source)
        lines = source.each_line.to_a
        start = lines.index { |line| line.match?(/\A\s*define\s+(?:[-\w]+\s+)*(?:i32|void)\s+@main\s*\(/) }
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
          if (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+\[(\d+)\s+x\s+i(?:8|16|32)\](?:,\s+align\s+\d+)?\z/))
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
          "    enum { PF_LLVM_SLOT_COUNT = #{[slot_count, 1].max} };",
          "    unsigned int llvm_slots[PF_LLVM_SLOT_COUNT] = {0};",
          "    int pf_return_code = 0;",
          "    int pf_slot_index = 0;",
          "    int pf_ch = 0;"
        ]
        registers.each_value do |name|
          lines << "    unsigned int #{name} = 0;"
        end
        lines << "    (void)llvm_slots;"
        lines << "    (void)pf_slot_index;"
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
        output = ["#{c_label(label)}:", "    (void)0;"]
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
        return emit_binary(line) if line.match?(/\A#{NAME}\s*=\s*(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)\b/)
        return emit_select(line) if line.match?(/\A#{NAME}\s*=\s*select\b/)
        return emit_cast(line) if line.match?(/\A#{NAME}\s*=\s*(zext|sext|trunc)\b/)
        return emit_icmp(line) if line.match?(/\A#{NAME}\s*=\s*icmp\b/)
        return emit_call(line) if line.include?("call ")
        return emit_switch(label, line) if line.start_with?("switch ")
        return emit_branch(label, line) if line.start_with?("br ")
        return emit_return(line) if line.start_with?("ret ")

        raise Frontend::LLVMSubset::ParseError, "unsupported LLVM instruction: #{line}"
      end

      def emit_gep(line)
        if (match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+inbounds)?\s+\[(\d+)\s+x\s+i(?:8|16|32)\],\s+ptr\s+(#{NAME}),\s+i\d+\s+(.+?),\s+i\d+\s+(.+)\z/))
          width = match[2].to_i
          base = pointer_expr(match[3])
          first_index = llvm_value(match[4])
          second_index = llvm_value(match[5])
          pointers[match[1]] = "((#{base}) + ((#{first_index}) * #{width}) + (#{second_index}))"
          return []
        end

        match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+inbounds)?\s+i(8|16|32),\s+ptr\s+(#{NAME}),\s+i\d+\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported getelementptr: #{line}" unless match

        pointers[match[1]] = "((#{pointer_expr(match[3])}) + (#{llvm_value(match[4])}))"
        []
      end

      def emit_store(line)
        match = line.match(/\Astore\s+i(8|16|32)\s+(.+?),\s+(?:ptr|i(?:8|16|32)\*)\s+(#{NAME})(?:,\s+align\s+\d+)?\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported store: #{line}" unless match

        slot_lines(match[3]) + [
          "    pf_set_u32(pf_sink, &llvm_slots[pf_slot_index], (unsigned int)(#{llvm_value(match[2])} & #{integer_mask(match[1].to_i)}u));"
        ]
      end

      def emit_load(line)
        match = line.match(/\A(#{NAME})\s*=\s*load\s+i(8|16|32),\s+(?:ptr|i(?:8|16|32)\*)\s+(#{NAME})(?:,\s+align\s+\d+)?\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported load: #{line}" unless match

        slot_lines(match[3]) + [
          "    #{register(match[1])} = (unsigned int)(llvm_slots[pf_slot_index] & #{integer_mask(match[2].to_i)}u);"
        ]
      end

      def emit_binary(line)
        match = line.match(/\A(#{NAME})\s*=\s*(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)\s+i(8|16|32)\s+(.+?),\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported binary op: #{line}" unless match

        bits = match[3].to_i
        expression = binary_expression(match[2], bits, llvm_value(match[4]), llvm_value(match[5]))
        ["    #{register(match[1])} = (unsigned int)((#{expression}) & #{integer_mask(bits)}u);"]
      end

      def emit_select(line)
        match = line.match(/\A(#{NAME})\s*=\s*select\s+i1\s+(.+?),\s+i(1|8|16|32)\s+(.+?),\s+i(?:1|8|16|32)\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported select: #{line}" unless match

        bits = match[3].to_i
        condition = llvm_value(match[2])
        true_value = llvm_value(match[4])
        false_value = llvm_value(match[5])
        ["    #{register(match[1])} = (unsigned int)((#{condition}) != 0u ? (#{true_value}) : (#{false_value})) & #{integer_mask(bits)}u;"]
      end

      def emit_cast(line)
        match = line.match(/\A(#{NAME})\s*=\s*(zext|sext|trunc)\s+i(1|8|16|32)\s+(.+?)\s+to\s+i(1|8|16|32)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported cast: #{line}" unless match

        value = llvm_value(match[4])
        bits = match[5].to_i
        ["    #{register(match[1])} = (unsigned int)((#{value}) & #{integer_mask(bits)}u);"]
      end

      def emit_icmp(line)
        match = line.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne|ugt|uge|ult|ule|sgt|sge|slt|sle)\s+i(8|16|32)\s+(.+?),\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported icmp: #{line}" unless match

        operator = icmp_operator(match[2])
        left = llvm_value(match[4])
        right = llvm_value(match[5])
        if match[2].start_with?("s")
          bits = match[3].to_i
          left = signed_expression(left, bits)
          right = signed_expression(right, bits)
        end
        ["    #{register(match[1])} = ((#{left}) #{operator} (#{right})) ? 1u : 0u;"]
      end

      def emit_call(line)
        if (match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@getchar\(\)\z/))
          output = ["    pf_ch = getchar();"]
          output << "    #{register(match[1])} = pf_ch == EOF ? 0u : (unsigned int)(unsigned char)pf_ch;" if match[1]
          return output
        end

        match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@putchar\(i32\s+(.+)\)\z/)
        return emit_internal_call(line) unless match

        output = ["    if (pf_output_cell((unsigned char)(#{llvm_value(match[2])})) != 0) PF_ABORT();"]
        output << "    #{register(match[1])} = 0u;" if match[1]
        output
      end

      def emit_internal_call(line)
        match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@([-A-Za-z$._0-9]+)\((.*)\)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported call: #{line}" unless match

        destination = match[1]
        function = internal_functions.fetch(match[2]) do
          raise Frontend::LLVMSubset::ParseError, "unsupported call: #{line}"
        end
        inline_function_call(destination, function, parse_call_arguments(match[3]))
      end

      def parse_call_arguments(raw)
        return [] if raw.strip.empty?

        raw.split(",").map do |argument|
          match = argument.strip.match(/\Ai(?:1|8|16|32)\s+(.+)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported call argument: #{argument}" unless match

          match[1]
        end
      end

      def inline_function_call(destination, function, arguments)
        unless arguments.length == function.fetch(:params).length
          raise Frontend::LLVMSubset::ParseError, "wrong argument count for internal call"
        end

        prefix = "pf_call_#{@inline_call_index}"
        @inline_call_index += 1
        locals = {}
        locals[:return_destination] = destination ? register(destination) : "#{prefix}_ignored_return"
        lines = []
        lines << "    unsigned int #{locals[:return_destination]} = 0;" unless destination
        function.fetch(:params).zip(arguments).each_with_index do |(param, argument), index|
          local = "#{prefix}_arg#{index}"
          locals[param] = local
          lines << "    unsigned int #{local} = (unsigned int)(#{llvm_value(argument)});"
        end

        function.fetch(:lines).each do |body_line|
          emitted = emit_inline_statement(body_line, locals, prefix)
          lines.concat(emitted)
          break if emitted.any? { |emitted_line| emitted_line.include?("/* pfc inline return */") }
        end

        if destination && !locals.key?(destination)
          raise Frontend::LLVMSubset::ParseError, "internal function did not return a value"
        end
        lines
      end

      def emit_inline_statement(line, locals, prefix)
        return emit_inline_binary(line, locals, prefix) if line.match?(/\A#{NAME}\s*=\s*(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)\b/)
        return emit_inline_select(line, locals, prefix) if line.match?(/\A#{NAME}\s*=\s*select\b/)
        return emit_inline_cast(line, locals, prefix) if line.match?(/\A#{NAME}\s*=\s*(zext|sext|trunc)\b/)
        return emit_inline_icmp(line, locals, prefix) if line.match?(/\A#{NAME}\s*=\s*icmp\b/)
        return emit_inline_return(line, locals) if line.start_with?("ret ")

        raise Frontend::LLVMSubset::ParseError, "unsupported internal function instruction: #{line}"
      end

      def emit_inline_binary(line, locals, prefix)
        match = line.match(/\A(#{NAME})\s*=\s*(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)\s+i(8|16|32)\s+(.+?),\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported binary op: #{line}" unless match

        local = inline_local(match[1], locals, prefix)
        expression = binary_expression(match[2], match[3].to_i, inline_value(match[4], locals), inline_value(match[5], locals))
        ["    unsigned int #{local} = (unsigned int)((#{expression}) & #{integer_mask(match[3].to_i)}u);"]
      end

      def emit_inline_select(line, locals, prefix)
        match = line.match(/\A(#{NAME})\s*=\s*select\s+i1\s+(.+?),\s+i(1|8|16|32)\s+(.+?),\s+i(?:1|8|16|32)\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported select: #{line}" unless match

        local = inline_local(match[1], locals, prefix)
        condition = inline_value(match[2], locals)
        true_value = inline_value(match[4], locals)
        false_value = inline_value(match[5], locals)
        ["    unsigned int #{local} = (unsigned int)(((#{condition}) != 0u ? (#{true_value}) : (#{false_value})) & #{integer_mask(match[3].to_i)}u);"]
      end

      def emit_inline_cast(line, locals, prefix)
        match = line.match(/\A(#{NAME})\s*=\s*(zext|sext|trunc)\s+i(1|8|16|32)\s+(.+?)\s+to\s+i(1|8|16|32)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported cast: #{line}" unless match

        local = inline_local(match[1], locals, prefix)
        ["    unsigned int #{local} = (unsigned int)((#{inline_value(match[4], locals)}) & #{integer_mask(match[5].to_i)}u);"]
      end

      def emit_inline_icmp(line, locals, prefix)
        match = line.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne|ugt|uge|ult|ule|sgt|sge|slt|sle)\s+i(8|16|32)\s+(.+?),\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported icmp: #{line}" unless match

        left = inline_value(match[4], locals)
        right = inline_value(match[5], locals)
        if match[2].start_with?("s")
          bits = match[3].to_i
          left = signed_expression(left, bits)
          right = signed_expression(right, bits)
        end
        local = inline_local(match[1], locals, prefix)
        ["    unsigned int #{local} = ((#{left}) #{icmp_operator(match[2])} (#{right})) ? 1u : 0u;"]
      end

      def emit_inline_return(line, locals)
        match = line.match(/\Aret\s+i32\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported internal return: #{line}" unless match

        ["    #{locals.fetch(:return_destination)} = (unsigned int)(#{inline_value(match[1], locals)}); /* pfc inline return */"]
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

      def emit_switch(label, line)
        match = line.match(/\Aswitch\s+i(8|16|32)\s+(.+?),\s+label\s+%([-A-Za-z$._0-9]+)\s+\[(.*)\]\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported switch: #{line}" unless match

        value = llvm_value(match[2])
        default_label = match[3]
        cases = match[4].scan(/i(?:8|16|32)\s+(-?\d+),\s+label\s+%([-A-Za-z$._0-9]+)/)
        lines = []
        cases.each_with_index do |(case_value, case_label), index|
          prefix = index.zero? ? "if" : "else if"
          lines << "    #{prefix} ((#{value}) == #{case_value}u) {"
          lines.concat(phi_goto(label, case_label, indent: 2))
          lines << "    }"
        end
        lines << "    else {"
        lines.concat(phi_goto(label, default_label, indent: 2))
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

      def inline_local(name, locals, prefix)
        locals.fetch(name) do
          local = "#{prefix}_#{name.delete_prefix('%').gsub(/[^A-Za-z0-9_]/, '_')}"
          locals[name] = local
          local
        end
      end

      def inline_value(raw, locals)
        token = raw.strip.split(/\s+/).last
        return token if token.match?(/\A-?\d+\z/)
        return locals[token] if locals.key?(token)
        return register(token) if token.match?(/\A#{NAME}\z/)

        raise Frontend::LLVMSubset::ParseError, "unsupported value: #{raw}"
      end

      def pointer_expr(name)
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

      def slot_lines(pointer_name)
        [
          "    pf_slot_index = (int)(#{pointer_expr(pointer_name)});",
          "    if (pf_slot_index < 0 || pf_slot_index >= PF_LLVM_SLOT_COUNT) {",
          "        fprintf(stderr, \"pfc runtime error: LLVM slot out of range: %d\\n\", pf_slot_index);",
          "        PF_ABORT();",
          "    }"
        ]
      end

      def binary_expression(operator, bits, left, right)
        case operator
        when "add" then "(#{left}) + (#{right})"
        when "sub" then "(#{left}) - (#{right})"
        when "mul" then "(#{left}) * (#{right})"
        when "udiv" then "(#{left}) / (#{right})"
        when "urem" then "(#{left}) % (#{right})"
        when "sdiv" then "(#{signed_expression(left, bits)}) / (#{signed_expression(right, bits)})"
        when "srem" then "(#{signed_expression(left, bits)}) % (#{signed_expression(right, bits)})"
        when "and" then "(#{left}) & (#{right})"
        when "or" then "(#{left}) | (#{right})"
        when "xor" then "(#{left}) ^ (#{right})"
        when "shl" then "(#{left}) << (#{right})"
        when "lshr" then "(#{left}) >> (#{right})"
        when "ashr" then "(unsigned int)((#{signed_expression(left, bits)}) >> (#{right}))"
        end
      end

      def signed_expression(value, bits)
        mask = integer_mask(bits)
        sign_bit = 1 << (bits - 1)
        "((int)(((#{value}) & #{sign_bit}u) ? ((#{value}) | ~#{mask}u) : ((#{value}) & #{mask}u)))"
      end

      def icmp_operator(predicate)
        case predicate
        when "eq" then "=="
        when "ne" then "!="
        when "ugt", "sgt" then ">"
        when "uge", "sge" then ">="
        when "ult", "slt" then "<"
        when "ule", "sle" then "<="
        end
      end
    end
  end
end
