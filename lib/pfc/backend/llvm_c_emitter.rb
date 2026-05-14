# frozen_string_literal: true

require_relative "c_emitter"
require_relative "printf_primitives"
require_relative "../frontend/llvm_subset"
require_relative "../frontend/llvm_subset/parser"

module PFC
  module Backend
    class LLVMCEmitter
      DEFAULT_TAPE_SIZE = CEmitter::DEFAULT_TAPE_SIZE
      NAME = /%[-A-Za-z$._0-9]+/
      GLOBAL_NAME = /@[-A-Za-z$._0-9]+/
      POINTER_NAME = /(?:#{NAME}|#{GLOBAL_NAME})/
      GlobalStringPointer = Struct.new(:name, :offset, keyword_init: true)
      GlobalMemoryPointer = Struct.new(:name, :offset, keyword_init: true)
      MemoryAddress = Struct.new(:limit, :memory, :name, :offset, :readonly, keyword_init: true)
      BUILTIN_FUNCTION_SIGNATURES = {
        "getchar" => { return_type: "i32", parameter_types: [], varargs: false },
        "printf" => { return_type: "i32", parameter_types: ["ptr"], varargs: true },
        "putchar" => { return_type: "i32", parameter_types: ["i32"], varargs: false },
        "puts" => { return_type: "i32", parameter_types: ["ptr"], varargs: false }
      }.freeze

      def initialize(source, tape_size: DEFAULT_TAPE_SIZE)
        parsed = Frontend::LLVMSubset::Parser.parse(source)
        @source = parsed.fetch(:source)
        @tape_size = Integer(tape_size)
        @function_signatures = parsed.fetch(:function_signatures)
        @global_numeric_data = parsed.fetch(:global_numeric_data)
        @global_numeric_mutability = parsed.fetch(:global_numeric_mutability)
        @global_strings = parsed.fetch(:global_strings)
        @internal_functions = parsed.fetch(:internal_functions)
        @blocks = parsed.fetch(:blocks)
        @block_order = parsed.fetch(:block_order)
        @source_line_numbers = parsed.fetch(:source_line_numbers)
        @slots = {}
        @slot_count = 0
        @pointers = {}
        @global_numeric_offsets, @global_numeric_bytes = build_global_numeric_layout
        @registers = {}
        @inline_call_index = 0
        @memory_intrinsic_index = 0
        @printf_call_index = 0
        @phi_temp_index = 0
        validate_tape_size!
        validate_builtin_declarations!
        analyze_global_numeric_pointers
        analyze_allocations
        analyze_registers
      end

      def emit
        lines = []
        lines << "#include <stdio.h>"
        lines << ""
        lines << PrintfPrimitives.source(tape_size: tape_size).rstrip
        lines << ""
        lines << llvm_memory_primitives.rstrip
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

      def dump_cfg
        lines = [
          "LLVMSubsetCFG",
          "main:",
          "  slots: #{slot_count}",
          "  registers: #{registers.keys.sort.join(', ')}"
        ]
        global_names = (global_strings.keys + global_numeric_data.keys).sort
        lines << "  globals: #{global_names.join(', ')}" unless global_names.empty?
        lines.concat(dump_blocks(block_order, blocks, indent: "  "))

        unless internal_functions.empty?
          lines << "functions:"
          internal_functions.keys.sort.each do |name|
            function = internal_functions.fetch(name)
            lines << "  @#{name}(#{function.fetch(:params).join(', ')}) -> #{function.fetch(:return_type)}"
            lines << "    slots: #{function.fetch(:allocations).length}"
            lines.concat(dump_blocks(function.fetch(:block_order), function.fetch(:blocks), indent: "    "))
          end
        end

        "#{lines.join("\n")}\n"
      end

      private

      attr_reader :blocks, :block_order, :function_signatures, :global_numeric_bytes, :global_numeric_data, :global_numeric_mutability, :global_numeric_offsets, :global_strings, :internal_functions, :pointers, :registers, :slot_count, :source, :tape_size

      def validate_tape_size!
        return if tape_size.between?(1, 65_535)

        raise ArgumentError, "tape size must be between 1 and 65535"
      end

      def build_global_numeric_layout
        offsets = {}
        bytes = []
        global_numeric_data.each do |name, global_bytes|
          offsets[name] = bytes.length
          bytes.concat(global_bytes)
        end

        [offsets, bytes]
      end

      def analyze_global_numeric_pointers
        global_numeric_offsets.each do |name, offset|
          pointers[name] = GlobalMemoryPointer.new(name:, offset:)
        end
      end

      def analyze_allocations
        all_lines.each do |line|
          if (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+\[(\d+)\s+x\s+i(1|8|16|32|64)\](?:,\s+align\s+\d+)?\z/))
            allocate_pointer(match[1], match[2].to_i * byte_width(match[3].to_i))
          elsif (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+i(1|8|16|32|64)(?:,\s+align\s+\d+)?\z/))
            allocate_pointer(match[1], byte_width(match[2].to_i))
          end
        end

        internal_functions.each_value do |function|
          function.fetch(:blocks).values.flatten.each do |line|
            if (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+\[(\d+)\s+x\s+i(1|8|16|32|64)\](?:,\s+align\s+\d+)?\z/))
              function.fetch(:allocations)[match[1]] = allocate_slots(match[2].to_i * byte_width(match[3].to_i))
            elsif (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+i(1|8|16|32|64)(?:,\s+align\s+\d+)?\z/))
              function.fetch(:allocations)[match[1]] = allocate_slots(byte_width(match[2].to_i))
            end
          end
        end
      end

      def analyze_registers
        all_lines.each do |line|
          lhs = line[/\A(#{NAME})\s*=/, 1]
          next if lhs.nil?
          next if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*alloca\b/)
          next if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*getelementptr\b/)
          next if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*inttoptr\b/)

          registers[lhs] = c_value_name(lhs)
        end
      end

      def all_lines
        blocks.values.flatten
      end

      def allocate_pointer(name, width)
        return if @slots.key?(name)

        @slots[name] = allocate_slots(width)
        pointers[name] = @slots.fetch(name)
      end

      def allocate_slots(width)
        slot = slot_count
        @slot_count += width
        slot
      end

      def dump_blocks(order, block_map, indent:)
        order.flat_map do |label|
          lines = ["#{indent}block #{label}:"]
          block_map.fetch(label).each do |instruction|
            prefix = instruction_kind(instruction) == :phi ? "phi" : "inst"
            line = instruction_text(instruction)
            lines << "#{indent}  #{prefix}: #{line}"
          end
          lines
        end
      end

      def llvm_memory_primitives
        <<~C
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
        C
      end

      def global_memory_initializer
        bytes = global_numeric_bytes.empty? ? [0] : global_numeric_bytes
        bytes.map { |byte| "#{byte}u" }.join(", ")
      end

      def main_prelude
        lines = [
          "    FILE *pf_sink = tmpfile();",
          "    if (pf_sink == NULL) {",
          "        perror(\"tmpfile\");",
          "        return 1;",
          "    }",
          "",
          "    enum { PF_LLVM_MEMORY_SIZE = #{[slot_count, 1].max} };",
          "    enum { PF_LLVM_GLOBAL_MEMORY_SIZE = #{[global_numeric_bytes.length, 1].max} };",
          "    unsigned char llvm_memory[PF_LLVM_MEMORY_SIZE] = {0};",
          "    unsigned char llvm_global_memory[PF_LLVM_GLOBAL_MEMORY_SIZE] = {#{global_memory_initializer}};",
          "    int pf_return_code = 0;",
          "    int pf_slot_index = 0;",
          "    int pf_ch = 0;"
        ]
        registers.each_value do |name|
          lines << "    unsigned long long #{name} = 0;"
        end
        lines << "    (void)llvm_memory;"
        lines << "    (void)llvm_global_memory;"
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
        with_statement_context(line) do
          case instruction_kind(line)
          when :gep then return emit_gep(line)
          when :alloca then return []
          when :store then return emit_store(line)
          when :load then return emit_load(line)
          when :binary then return emit_binary(line)
          when :select then return emit_select(line)
          when :cast then return emit_cast(line)
          when :icmp then return emit_icmp(line)
          when :call then return emit_call(line)
          when :switch then return emit_switch(label, line)
          when :branch then return emit_branch(label, line)
          when :return then return emit_return(line)
          end

          raise Frontend::LLVMSubset::ParseError, "unsupported LLVM instruction: #{line}"
        end
      end

      def emit_gep(line)
        if line.respond_to?(:destination) && line.respond_to?(:base_pointer) && line.respond_to?(:element_bits) && line.element_bits
          if global_strings.key?(line.base_pointer) && line.array_count && line.element_bits == 8 && line.indices.all? { |index| index.match?(/\A-?\d+\z/) }
            pointers[line.destination] = GlobalStringPointer.new(
              name: line.base_pointer,
              offset: (line.indices.fetch(0).to_i * line.array_count) + line.indices.fetch(1).to_i
            )
            return []
          end

          base_address = memory_address(line.base_pointer)
          if line.array_count
            element_width = byte_width(line.element_bits)
            aggregate_width = line.array_count * element_width
            first_index = llvm_value(line.indices.fetch(0))
            second_index = llvm_value(line.indices.fetch(1))
            offset = "((#{base_address.offset}) + ((#{first_index}) * #{aggregate_width}) + ((#{second_index}) * #{element_width}))"
          else
            offset = "((#{base_address.offset}) + ((#{llvm_value(line.indices.fetch(0))}) * #{byte_width(line.element_bits)}))"
          end
          pointers[line.destination] = pointer_from_address(base_address, offset)
          return []
        end

        if (match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+inbounds)?\s+\[(\d+)\s+x\s+i8\],\s+ptr\s+(#{GLOBAL_NAME}),\s+i\d+\s+(-?\d+),\s+i\d+\s+(-?\d+)\z/)) && global_strings.key?(match[3])
          pointers[match[1]] = GlobalStringPointer.new(
            name: match[3],
            offset: (match[4].to_i * match[2].to_i) + match[5].to_i
          )
          return []
        end

        if (match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+inbounds)?\s+\[(\d+)\s+x\s+i(1|8|16|32|64)\],\s+ptr\s+(#{POINTER_NAME}),\s+i\d+\s+(.+?),\s+i\d+\s+(.+)\z/))
          element_width = byte_width(match[3].to_i)
          aggregate_width = match[2].to_i * element_width
          base_address = memory_address(match[4])
          base = base_address.offset
          first_index = llvm_value(match[5])
          second_index = llvm_value(match[6])
          offset = "((#{base}) + ((#{first_index}) * #{aggregate_width}) + ((#{second_index}) * #{element_width}))"
          pointers[match[1]] = pointer_from_address(base_address, offset)
          return []
        end

        match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+inbounds)?\s+i(1|8|16|32|64),\s+ptr\s+(#{POINTER_NAME}),\s+i\d+\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported getelementptr: #{line}" unless match

        base_address = memory_address(match[3])
        offset = "((#{base_address.offset}) + ((#{llvm_value(match[4])}) * #{byte_width(match[2].to_i)}))"
        pointers[match[1]] = pointer_from_address(base_address, offset)
        []
      end

      def emit_store(line)
        if line.respond_to?(:bits) && line.respond_to?(:value) && line.respond_to?(:pointer) && line.bits
          bits = line.bits
          value = line.value
          pointer = line.pointer
        else
          match = line.match(/\Astore\s+i(1|8|16|32|64)\s+(.+?),\s+(?:ptr|i(?:1|8|16|32|64)\*)\s+(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported store: #{line}" unless match

          bits = match[1].to_i
          value = match[2]
          pointer = match[3]
        end
        width = byte_width(bits)
        address = memory_address(pointer)
        ensure_writable_address!(address)
        slot_lines(address, width) + [
          "    pf_llvm_store(#{address.memory}, pf_slot_index, (unsigned long long)(#{llvm_value(value)} & #{integer_mask_literal(bits)}), #{width});"
        ]
      end

      def emit_load(line)
        if line.respond_to?(:destination) && line.respond_to?(:bits) && line.respond_to?(:pointer) && line.bits
          destination = line.destination
          bits = line.bits
          pointer = line.pointer
        else
          match = line.match(/\A(#{NAME})\s*=\s*load\s+i(1|8|16|32|64),\s+(?:ptr|i(?:1|8|16|32|64)\*)\s+(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported load: #{line}" unless match

          destination = match[1]
          bits = match[2].to_i
          pointer = match[3]
        end
        width = byte_width(bits)
        address = memory_address(pointer)
        slot_lines(address, width) + [
          "    #{register(destination)} = #{unsigned_cast(bits)}(pf_llvm_load(#{address.memory}, pf_slot_index, #{width}) & #{integer_mask_literal(bits)});"
        ]
      end

      def emit_binary(line)
        if line.respond_to?(:destination) && line.respond_to?(:operator) && line.respond_to?(:bits) && line.bits
          destination = line.destination
          operator = line.operator
          bits = line.bits
          left = line.left
          right = line.right
        else
          match = line.match(/\A(#{NAME})\s*=\s*(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)(?:\s+(?:nuw|nsw|exact))*\s+i(1|8|16|32|64)\s+(.+?),\s+(.+)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported binary op: #{line}" unless match

          destination = match[1]
          operator = match[2]
          bits = match[3].to_i
          left = match[4]
          right = match[5]
        end
        expression = binary_expression(operator, bits, llvm_value(left), llvm_value(right))
        ["    #{register(destination)} = #{unsigned_cast(bits)}((#{expression}) & #{integer_mask_literal(bits)});"]
      end

      def emit_select(line)
        match = line.match(/\A(#{NAME})\s*=\s*select\s+i1\s+(.+?),\s+i(1|8|16|32|64)\s+(.+?),\s+i(?:1|8|16|32|64)\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported select: #{line}" unless match

        bits = match[3].to_i
        condition = llvm_value(match[2])
        true_value = llvm_value(match[4])
        false_value = llvm_value(match[5])
        ["    #{register(match[1])} = #{unsigned_cast(bits)}(((#{condition}) != 0u ? (#{true_value}) : (#{false_value})) & #{integer_mask_literal(bits)});"]
      end

      def emit_cast(line)
        if line.respond_to?(:destination) && line.respond_to?(:operator) && line.operator
          return emit_ptrtoint_cast(line.destination, line.value, line.to_bits) if line.operator == "ptrtoint"
          return emit_inttoptr_cast(line.destination, line.value) if line.operator == "inttoptr"

          if line.from_bits
            destination = line.destination
            operator = line.operator
            from_bits = line.from_bits
            value = line.value
            to_bits = line.to_bits
          end
        elsif (match = line.match(/\A(#{NAME})\s*=\s*ptrtoint\s+ptr\s+(#{POINTER_NAME})\s+to\s+i(1|8|16|32|64)\z/))
          return emit_ptrtoint_cast(match[1], match[2], match[3].to_i)
        elsif (match = line.match(/\A(#{NAME})\s*=\s*inttoptr\s+i(?:1|8|16|32|64)\s+(.+?)\s+to\s+ptr\z/))
          return emit_inttoptr_cast(match[1], match[2])
        else
          match = line.match(/\A(#{NAME})\s*=\s*(zext|sext|trunc)\s+i(1|8|16|32|64)\s+(.+?)\s+to\s+i(1|8|16|32|64)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported cast: #{line}" unless match

          destination = match[1]
          operator = match[2]
          from_bits = match[3].to_i
          value = match[4]
          to_bits = match[5].to_i
        end
        raise Frontend::LLVMSubset::ParseError, "unsupported cast: #{line}" unless from_bits

        ["    #{register(destination)} = #{cast_expression(operator, from_bits, to_bits, llvm_value(value))};"]
      end

      def emit_ptrtoint_cast(destination, value, to_bits, context: nil)
        address = memory_address(value, context:)
        target = context ? inline_register(context, destination) : register(destination)
        ["    #{target} = #{unsigned_cast(to_bits)}(((unsigned long long)(#{address.offset})) & #{integer_mask_literal(to_bits)});"]
      end

      def emit_inttoptr_cast(destination, value, context: nil)
        pointer = context ? inline_value(value, context) : llvm_value(value)
        pointer_map = context ? context.fetch(:pointers) : pointers
        pointer_map[destination] = pointer
        []
      end

      def emit_icmp(line)
        if line.respond_to?(:destination) && line.respond_to?(:predicate) && line.respond_to?(:bits) && line.bits
          destination = line.destination
          predicate = line.predicate
          bits = line.bits
          left = llvm_value(line.left)
          right = llvm_value(line.right)
        else
          match = line.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne|ugt|uge|ult|ule|sgt|sge|slt|sle)\s+i(1|8|16|32|64)\s+(.+?),\s+(.+)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported icmp: #{line}" unless match

          destination = match[1]
          predicate = match[2]
          bits = match[3].to_i
          left = llvm_value(match[4])
          right = llvm_value(match[5])
        end
        operator = icmp_operator(predicate)
        if predicate.start_with?("s")
          left = signed_expression(left, bits)
          right = signed_expression(right, bits)
        end
        ["    #{register(destination)} = ((#{left}) #{operator} (#{right})) ? 1u : 0u;"]
      end

      def emit_call(line)
        call = parsed_call(line)
        validate_call_signature!(call, line)
        return emit_memory_intrinsic_call(call) if llvm_memory_intrinsic?(call.fetch(:function_name))

        if (match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@getchar\(\)\z/))
          output = ["    pf_ch = getchar();"]
          output << "    #{register(match[1])} = pf_ch == EOF ? 0u : (unsigned int)(unsigned char)pf_ch;" if match[1]
          return output
        end

        if (match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@puts\(ptr(?:\s+\w+)*\s+(.+)\)\z/))
          return emit_puts_call(match[1], match[2])
        end

        if (match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+(?:\(ptr,\s+\.\.\.\)\s+)?@printf\((.+)\)\z/))
          return emit_printf_call(match[1], match[2])
        end

        match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@putchar\(i32\s+(.+)\)\z/)
        return emit_internal_call(line) unless match

        output = ["    if (pf_output_cell((unsigned char)(#{llvm_value(match[2])})) != 0) PF_ABORT();"]
        output << "    #{register(match[1])} = 0u;" if match[1]
        output
      end

      def emit_internal_call(line)
        match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+(i(?:1|8|16|32|64)|void)\s+@([-A-Za-z$._0-9]+)\((.*)\)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported call: #{line}" unless match

        destination = match[1]
        return_type = match[2]
        function = internal_functions.fetch(match[3]) do
          raise Frontend::LLVMSubset::ParseError, "unsupported call: #{line}"
        end
        raise Frontend::LLVMSubset::ParseError, "void call cannot assign a result: #{line}" if destination && return_type == "void"
        unless return_type == function.fetch(:return_type)
          raise Frontend::LLVMSubset::ParseError, "internal call return type mismatch: #{line}"
        end

        inline_function_call(destination, function, parse_call_arguments(match[4]))
      end

      def parse_call_arguments(raw)
        parse_typed_call_arguments(raw).map { |argument| argument.fetch(:value) }
      end

      def inline_function_call(destination, function, arguments, caller_context: nil)
        unless arguments.length == function.fetch(:params).length
          raise Frontend::LLVMSubset::ParseError, "wrong argument count for internal call"
        end
        if destination && function.fetch(:return_type) == "void"
          raise Frontend::LLVMSubset::ParseError, "void internal call cannot assign a result: @#{function.fetch(:name)}"
        end

        prefix = "pf_call_#{@inline_call_index}"
        @inline_call_index += 1
        call_stack = caller_context ? caller_context.fetch(:call_stack) : []
        if call_stack.include?(function.fetch(:name))
          raise Frontend::LLVMSubset::ParseError, "recursive internal call is unsupported: @#{function.fetch(:name)}"
        end

        return_destination = if destination
                               caller_context ? inline_register(caller_context, destination) : register(destination)
                             else
                               "#{prefix}_ignored_return"
                             end
        context = inline_context(prefix, return_destination, function, call_stack + [function.fetch(:name)])
        lines = inline_declarations(context, function)
        function.fetch(:params).zip(arguments).each_with_index do |(param, argument), index|
          local = context.fetch(:values).fetch(param)
          value = caller_context ? inline_value(argument, caller_context) : llvm_value(argument)
          lines << "    #{local} = (unsigned long long)(#{value});"
        end

        lines << "    goto #{inline_label(context, "entry")};"
        function.fetch(:block_order).each do |label|
          lines.concat(emit_inline_block(context, label, function.fetch(:blocks).fetch(label)))
        end
        lines << "#{context.fetch(:return_label)}:"
        lines << "    (void)0;"
        lines
      end

      def inline_context(prefix, return_destination, function, call_stack)
        values = {}
        pointers = function.fetch(:allocations).dup
        function.fetch(:params).each_with_index do |param, index|
          values[param] = "#{prefix}_arg#{index}"
        end
        inline_register_names(function).each do |name|
          values[name] ||= "#{prefix}_#{name.delete_prefix('%').gsub(/[^A-Za-z0-9_]/, '_')}"
        end
        {
          call_stack:,
          declare_return_destination: function.fetch(:return_type) != "void" &&
            return_destination.start_with?("#{prefix}_ignored_return"),
          function:,
          pointers:,
          prefix:,
          return_destination:,
          return_label: "#{prefix}_return",
          values:
        }
      end

      def inline_register_names(function)
        function.fetch(:blocks).values.flatten.filter_map do |line|
          lhs = line[/\A(#{NAME})\s*=/, 1]
          next nil if lhs.nil?
          next nil if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*alloca\b/)
          next nil if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*getelementptr\b/)
          next nil if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*inttoptr\b/)

          lhs
        end.uniq
      end

      def inline_declarations(context, function)
        declared = []
        lines = []
        function.fetch(:params).each do |param|
          name = context.fetch(:values).fetch(param)
          lines << "    unsigned long long #{name} = 0;"
          declared << name
        end
        inline_register_names(function).each do |register_name|
          name = context.fetch(:values).fetch(register_name)
          next if declared.include?(name)

          lines << "    unsigned long long #{name} = 0;"
          declared << name
        end
        lines << "    unsigned long long #{context.fetch(:return_destination)} = 0;" if context.fetch(:declare_return_destination)
        lines
      end

      def emit_inline_block(context, label, lines)
        output = ["#{inline_label(context, label)}:", "    (void)0;"]
        lines.reject { |line| phi?(line) }.each do |line|
          output.concat(emit_inline_statement(line, context, label))
        end
        output
      end

      def emit_inline_statement(line, context, label)
        with_statement_context(line) do
          case instruction_kind(line)
          when :gep then return emit_inline_gep(line, context)
          when :alloca then return []
          when :store then return emit_inline_store(line, context)
          when :load then return emit_inline_load(line, context)
          when :binary then return emit_inline_binary(line, context)
          when :select then return emit_inline_select(line, context)
          when :cast then return emit_inline_cast(line, context)
          when :icmp then return emit_inline_icmp(line, context)
          when :call then return emit_inline_call(line, context)
          when :switch then return emit_inline_switch(line, context, label)
          when :branch then return emit_inline_branch(line, context, label)
          when :return then return emit_inline_return(line, context)
          end

          raise Frontend::LLVMSubset::ParseError, "unsupported internal function instruction: #{line}"
        end
      end

      def emit_inline_gep(line, context)
        if line.respond_to?(:destination) && line.respond_to?(:base_pointer) && line.respond_to?(:element_bits) && line.element_bits
          if global_strings.key?(line.base_pointer) && line.array_count && line.element_bits == 8 && line.indices.all? { |index| index.match?(/\A-?\d+\z/) }
            context.fetch(:pointers)[line.destination] = GlobalStringPointer.new(
              name: line.base_pointer,
              offset: (line.indices.fetch(0).to_i * line.array_count) + line.indices.fetch(1).to_i
            )
            return []
          end

          base_address = memory_address(line.base_pointer, context:)
          if line.array_count
            element_width = byte_width(line.element_bits)
            aggregate_width = line.array_count * element_width
            first_index = inline_value(line.indices.fetch(0), context)
            second_index = inline_value(line.indices.fetch(1), context)
            offset = "((#{base_address.offset}) + ((#{first_index}) * #{aggregate_width}) + ((#{second_index}) * #{element_width}))"
          else
            offset = "((#{base_address.offset}) + ((#{inline_value(line.indices.fetch(0), context)}) * #{byte_width(line.element_bits)}))"
          end
          context.fetch(:pointers)[line.destination] = pointer_from_address(base_address, offset)
          return []
        end

        if (match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+inbounds)?\s+\[(\d+)\s+x\s+i8\],\s+ptr\s+(#{GLOBAL_NAME}),\s+i\d+\s+(-?\d+),\s+i\d+\s+(-?\d+)\z/)) && global_strings.key?(match[3])
          context.fetch(:pointers)[match[1]] = GlobalStringPointer.new(
            name: match[3],
            offset: (match[4].to_i * match[2].to_i) + match[5].to_i
          )
          return []
        end

        if (match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+inbounds)?\s+\[(\d+)\s+x\s+i(1|8|16|32|64)\],\s+ptr\s+(#{POINTER_NAME}),\s+i\d+\s+(.+?),\s+i\d+\s+(.+)\z/))
          element_width = byte_width(match[3].to_i)
          aggregate_width = match[2].to_i * element_width
          base_address = memory_address(match[4], context:)
          base = base_address.offset
          first_index = inline_value(match[5], context)
          second_index = inline_value(match[6], context)
          offset = "((#{base}) + ((#{first_index}) * #{aggregate_width}) + ((#{second_index}) * #{element_width}))"
          context.fetch(:pointers)[match[1]] = pointer_from_address(base_address, offset)
          return []
        end

        match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+inbounds)?\s+i(1|8|16|32|64),\s+ptr\s+(#{POINTER_NAME}),\s+i\d+\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported getelementptr: #{line}" unless match

        base_address = memory_address(match[3], context:)
        offset = "((#{base_address.offset}) + ((#{inline_value(match[4], context)}) * #{byte_width(match[2].to_i)}))"
        context.fetch(:pointers)[match[1]] = pointer_from_address(base_address, offset)
        []
      end

      def emit_inline_store(line, context)
        if line.respond_to?(:bits) && line.respond_to?(:value) && line.respond_to?(:pointer) && line.bits
          bits = line.bits
          value = line.value
          pointer = line.pointer
        else
          match = line.match(/\Astore\s+i(1|8|16|32|64)\s+(.+?),\s+(?:ptr|i(?:1|8|16|32|64)\*)\s+(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported store: #{line}" unless match

          bits = match[1].to_i
          value = match[2]
          pointer = match[3]
        end
        width = byte_width(bits)
        address = memory_address(pointer, context:)
        ensure_writable_address!(address)
        inline_slot_lines(address, width) + [
          "    pf_llvm_store(#{address.memory}, pf_slot_index, (unsigned long long)(#{inline_value(value, context)} & #{integer_mask_literal(bits)}), #{width});"
        ]
      end

      def emit_inline_load(line, context)
        if line.respond_to?(:destination) && line.respond_to?(:bits) && line.respond_to?(:pointer) && line.bits
          destination = line.destination
          bits = line.bits
          pointer = line.pointer
        else
          match = line.match(/\A(#{NAME})\s*=\s*load\s+i(1|8|16|32|64),\s+(?:ptr|i(?:1|8|16|32|64)\*)\s+(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported load: #{line}" unless match

          destination = match[1]
          bits = match[2].to_i
          pointer = match[3]
        end
        width = byte_width(bits)
        address = memory_address(pointer, context:)
        inline_slot_lines(address, width) + [
          "    #{inline_register(context, destination)} = #{unsigned_cast(bits)}(pf_llvm_load(#{address.memory}, pf_slot_index, #{width}) & #{integer_mask_literal(bits)});"
        ]
      end

      def emit_inline_binary(line, context)
        if line.respond_to?(:destination) && line.respond_to?(:operator) && line.respond_to?(:bits) && line.bits
          destination = line.destination
          operator = line.operator
          bits = line.bits
          left = line.left
          right = line.right
        else
          match = line.match(/\A(#{NAME})\s*=\s*(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)(?:\s+(?:nuw|nsw|exact))*\s+i(1|8|16|32|64)\s+(.+?),\s+(.+)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported binary op: #{line}" unless match

          destination = match[1]
          operator = match[2]
          bits = match[3].to_i
          left = match[4]
          right = match[5]
        end
        local = inline_register(context, destination)
        expression = binary_expression(operator, bits, inline_value(left, context), inline_value(right, context))
        ["    #{local} = #{unsigned_cast(bits)}((#{expression}) & #{integer_mask_literal(bits)});"]
      end

      def emit_inline_select(line, context)
        match = line.match(/\A(#{NAME})\s*=\s*select\s+i1\s+(.+?),\s+i(1|8|16|32|64)\s+(.+?),\s+i(?:1|8|16|32|64)\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported select: #{line}" unless match

        local = inline_register(context, match[1])
        condition = inline_value(match[2], context)
        true_value = inline_value(match[4], context)
        false_value = inline_value(match[5], context)
        ["    #{local} = #{unsigned_cast(match[3].to_i)}(((#{condition}) != 0u ? (#{true_value}) : (#{false_value})) & #{integer_mask_literal(match[3].to_i)});"]
      end

      def emit_inline_cast(line, context)
        if line.respond_to?(:destination) && line.respond_to?(:operator) && line.operator
          return emit_ptrtoint_cast(line.destination, line.value, line.to_bits, context:) if line.operator == "ptrtoint"
          return emit_inttoptr_cast(line.destination, line.value, context:) if line.operator == "inttoptr"

          if line.from_bits
            destination = line.destination
            operator = line.operator
            from_bits = line.from_bits
            value = line.value
            to_bits = line.to_bits
          end
        elsif (match = line.match(/\A(#{NAME})\s*=\s*ptrtoint\s+ptr\s+(#{POINTER_NAME})\s+to\s+i(1|8|16|32|64)\z/))
          return emit_ptrtoint_cast(match[1], match[2], match[3].to_i, context:)
        elsif (match = line.match(/\A(#{NAME})\s*=\s*inttoptr\s+i(?:1|8|16|32|64)\s+(.+?)\s+to\s+ptr\z/))
          return emit_inttoptr_cast(match[1], match[2], context:)
        else
          match = line.match(/\A(#{NAME})\s*=\s*(zext|sext|trunc)\s+i(1|8|16|32|64)\s+(.+?)\s+to\s+i(1|8|16|32|64)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported cast: #{line}" unless match

          destination = match[1]
          operator = match[2]
          from_bits = match[3].to_i
          value = match[4]
          to_bits = match[5].to_i
        end
        raise Frontend::LLVMSubset::ParseError, "unsupported cast: #{line}" unless from_bits

        local = inline_register(context, destination)
        ["    #{local} = #{cast_expression(operator, from_bits, to_bits, inline_value(value, context))};"]
      end

      def emit_inline_icmp(line, context)
        if line.respond_to?(:destination) && line.respond_to?(:predicate) && line.respond_to?(:bits) && line.bits
          destination = line.destination
          predicate = line.predicate
          bits = line.bits
          left = inline_value(line.left, context)
          right = inline_value(line.right, context)
        else
          match = line.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne|ugt|uge|ult|ule|sgt|sge|slt|sle)\s+i(1|8|16|32|64)\s+(.+?),\s+(.+)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported icmp: #{line}" unless match

          destination = match[1]
          predicate = match[2]
          bits = match[3].to_i
          left = inline_value(match[4], context)
          right = inline_value(match[5], context)
        end
        if predicate.start_with?("s")
          left = signed_expression(left, bits)
          right = signed_expression(right, bits)
        end
        local = inline_register(context, destination)
        ["    #{local} = ((#{left}) #{icmp_operator(predicate)} (#{right})) ? 1u : 0u;"]
      end

      def emit_inline_call(line, context)
        call = parsed_call(line)
        validate_call_signature!(call, line)
        return emit_memory_intrinsic_call(call, context:) if llvm_memory_intrinsic?(call.fetch(:function_name))

        if (match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@getchar\(\)\z/))
          output = ["    pf_ch = getchar();"]
          output << "    #{inline_register(context, match[1])} = pf_ch == EOF ? 0u : (unsigned int)(unsigned char)pf_ch;" if match[1]
          return output
        end

        if (match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@puts\(ptr(?:\s+\w+)*\s+(.+)\)\z/))
          return emit_puts_call(match[1], match[2], context:)
        end

        if (match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+(?:\(ptr,\s+\.\.\.\)\s+)?@printf\((.+)\)\z/))
          return emit_printf_call(match[1], match[2], context:)
        end

        match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@putchar\(i32\s+(.+)\)\z/)
        unless match
          match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+(i(?:1|8|16|32|64)|void)\s+@([-A-Za-z$._0-9]+)\((.*)\)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported internal call: #{line}" unless match

          raise Frontend::LLVMSubset::ParseError, "void call cannot assign a result: #{line}" if match[1] && match[2] == "void"

          function = internal_functions.fetch(match[3]) do
            raise Frontend::LLVMSubset::ParseError, "unsupported internal call: #{line}"
          end
          unless match[2] == function.fetch(:return_type)
            raise Frontend::LLVMSubset::ParseError, "internal call return type mismatch: #{line}"
          end
          return inline_function_call(match[1], function, parse_call_arguments(match[4]), caller_context: context)
        end

        output = ["    if (pf_output_cell((unsigned char)(#{inline_value(match[2], context)})) != 0) PF_ABORT();"]
        output << "    #{inline_register(context, match[1])} = 0u;" if match[1]
        output
      end

      def emit_inline_switch(line, context, label)
        if line.respond_to?(:bits) && line.respond_to?(:value) && line.respond_to?(:default_label) && line.bits
          bits = line.bits
          value = inline_value(line.value, context)
          default_label = line.default_label
          cases = line.cases
        else
          match = line.match(/\Aswitch\s+i(1|8|16|32|64)\s+(.+?),\s+label\s+%([-A-Za-z$._0-9]+)\s+\[(.*)\]\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported switch: #{line}" unless match

          bits = match[1].to_i
          value = inline_value(match[2], context)
          default_label = match[3]
          cases = match[4].scan(/i(?:1|8|16|32|64)\s+(-?\d+),\s+label\s+%([-A-Za-z$._0-9]+)/)
        end
        lines = []
        cases.each_with_index do |(case_value, case_label), index|
          prefix = index.zero? ? "if" : "else if"
          lines << "    #{prefix} ((#{value}) == #{case_value}#{integer_suffix(bits)}) {"
          lines.concat(inline_phi_goto(context, label, case_label, indent: 2))
          lines << "    }"
        end
        lines << "    else {"
        lines.concat(inline_phi_goto(context, label, default_label, indent: 2))
        lines << "    }"
        lines
      end

      def emit_inline_branch(line, context, label)
        if line.respond_to?(:targets) && line.targets
          return inline_phi_goto(context, label, line.targets.fetch(0)) if line.condition.nil?

          true_label = line.targets.fetch(0)
          false_label = line.targets.fetch(1)
          lines = ["    if ((#{inline_value(line.condition, context)}) != 0u) {"]
          lines.concat(inline_phi_goto(context, label, true_label, indent: 2))
          lines << "    } else {"
          lines.concat(inline_phi_goto(context, label, false_label, indent: 2))
          lines << "    }"
          return lines
        end

        if (match = line.match(/\Abr\s+label\s+%([-A-Za-z$._0-9]+)\z/))
          return inline_phi_goto(context, label, match[1])
        end

        match = line.match(/\Abr\s+i1\s+(.+?),\s+label\s+%([-A-Za-z$._0-9]+),\s+label\s+%([-A-Za-z$._0-9]+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported branch: #{line}" unless match

        lines = ["    if ((#{inline_value(match[1], context)}) != 0u) {"]
        true_label = match[2]
        false_label = match[3]
        lines.concat(inline_phi_goto(context, label, true_label, indent: 2))
        lines << "    } else {"
        lines.concat(inline_phi_goto(context, label, false_label, indent: 2))
        lines << "    }"
        lines
      end

      def emit_inline_return(line, context)
        if line.respond_to?(:return_type) && line.return_type
          if line.return_type == "void"
            unless context.fetch(:function).fetch(:return_type) == "void"
              raise Frontend::LLVMSubset::ParseError, "unsupported internal return: #{line}"
            end

            return ["    goto #{context.fetch(:return_label)};"]
          end
          if context.fetch(:function).fetch(:return_type) == "void" || line.value.nil?
            raise Frontend::LLVMSubset::ParseError, "unsupported internal return: #{line}"
          end

          return [
            "    #{context.fetch(:return_destination)} = (unsigned long long)(#{inline_value(line.value, context)});",
            "    goto #{context.fetch(:return_label)};"
          ]
        end

        if line == "ret void"
          unless context.fetch(:function).fetch(:return_type) == "void"
            raise Frontend::LLVMSubset::ParseError, "unsupported internal return: #{line}"
          end

          return ["    goto #{context.fetch(:return_label)};"]
        end

        match = line.match(/\Aret\s+i(?:1|8|16|32|64)\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported internal return: #{line}" unless match
        if context.fetch(:function).fetch(:return_type) == "void"
          raise Frontend::LLVMSubset::ParseError, "unsupported internal return: #{line}"
        end

        [
          "    #{context.fetch(:return_destination)} = (unsigned long long)(#{inline_value(match[1], context)});",
          "    goto #{context.fetch(:return_label)};"
        ]
      end

      def emit_branch(label, line)
        if line.respond_to?(:targets) && line.targets
          return phi_goto(label, line.targets.fetch(0)) if line.condition.nil?

          true_label = line.targets.fetch(0)
          false_label = line.targets.fetch(1)
          lines = ["    if ((#{llvm_value(line.condition)}) != 0u) {"]
          lines.concat(phi_goto(label, true_label, indent: 2))
          lines << "    } else {"
          lines.concat(phi_goto(label, false_label, indent: 2))
          lines << "    }"
          return lines
        end

        if (match = line.match(/\Abr\s+label\s+%([-A-Za-z$._0-9]+)\z/))
          return phi_goto(label, match[1])
        end

        match = line.match(/\Abr\s+i1\s+(.+?),\s+label\s+%([-A-Za-z$._0-9]+),\s+label\s+%([-A-Za-z$._0-9]+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported branch: #{line}" unless match

        lines = ["    if ((#{llvm_value(match[1])}) != 0u) {"]
        true_label = match[2]
        false_label = match[3]
        lines.concat(phi_goto(label, true_label, indent: 2))
        lines << "    } else {"
        lines.concat(phi_goto(label, false_label, indent: 2))
        lines << "    }"
        lines
      end

      def emit_switch(label, line)
        if line.respond_to?(:bits) && line.respond_to?(:value) && line.respond_to?(:default_label) && line.bits
          bits = line.bits
          value = llvm_value(line.value)
          default_label = line.default_label
          cases = line.cases
        else
          match = line.match(/\Aswitch\s+i(1|8|16|32|64)\s+(.+?),\s+label\s+%([-A-Za-z$._0-9]+)\s+\[(.*)\]\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported switch: #{line}" unless match

          value = llvm_value(match[2])
          default_label = match[3]
          bits = match[1].to_i
          cases = match[4].scan(/i(?:1|8|16|32|64)\s+(-?\d+),\s+label\s+%([-A-Za-z$._0-9]+)/)
        end
        lines = []
        cases.each_with_index do |(case_value, case_label), index|
          prefix = index.zero? ? "if" : "else if"
          lines << "    #{prefix} ((#{value}) == #{case_value}#{integer_suffix(bits)}) {"
          lines.concat(phi_goto(label, case_label, indent: 2))
          lines << "    }"
        end
        lines << "    else {"
        lines.concat(phi_goto(label, default_label, indent: 2))
        lines << "    }"
        lines
      end

      def emit_return(line)
        if line.respond_to?(:return_type) && line.return_type
          return ["    goto pf_done;"] if line.return_type == "void"

          return [
            "    pf_return_code = (int)(#{llvm_value(line.value)});",
            "    goto pf_done;"
          ]
        end

        match = line.match(/\Aret\s+i(?:1|8|16|32|64)\s+(.+)\z/)
        return ["    goto pf_done;"] unless match

        [
          "    pf_return_code = (int)(#{llvm_value(match[1])});",
          "    goto pf_done;"
        ]
      end

      def phi_goto(from_label, to_label, indent: 1)
        spaces = "    " * indent
        assignments = phi_lines(to_label).filter_map do |line|
          phi_assignment(line, from_label)
        end
        lines = simultaneous_phi_assignment_lines(assignments, spaces)
        lines << "#{spaces}goto #{c_label(to_label)};"
        lines
      end

      def phi_lines(label)
        blocks.fetch(label).select { |line| phi?(line) }
      end

      def phi_assignment(line, from_label)
        if line.respond_to?(:incoming) && line.incoming && line.bits
          value = line.incoming.find { |_value, label| label == from_label }&.first
          return nil if value.nil?

          return {
            expression: "#{unsigned_cast(line.bits)}((#{llvm_value(value)}) & #{integer_mask_literal(line.bits)})",
            target: register(line.destination)
          }
        end

        match = line.match(/\A(#{NAME})\s*=\s*phi\s+i(1|8|16|32|64)\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported phi: #{line}" unless match

        incoming = match[3].scan(/\[\s*(.+?)\s*,\s+%([-A-Za-z$._0-9]+)\s*\]/)
        value = incoming.find { |_value, label| label == from_label }&.first
        return nil if value.nil?
        bits = match[2].to_i
        {
          expression: "#{unsigned_cast(bits)}((#{llvm_value(value)}) & #{integer_mask_literal(bits)})",
          target: register(match[1])
        }
      end

      def inline_phi_goto(context, from_label, to_label, indent: 1)
        spaces = "    " * indent
        assignments = inline_phi_lines(context, to_label).filter_map do |line|
          inline_phi_assignment(context, line, from_label)
        end
        lines = simultaneous_phi_assignment_lines(assignments, spaces)
        lines << "#{spaces}goto #{inline_label(context, to_label)};"
        lines
      end

      def inline_phi_lines(context, label)
        context.fetch(:function).fetch(:blocks).fetch(label).select { |line| phi?(line) }
      end

      def inline_phi_assignment(context, line, from_label)
        if line.respond_to?(:incoming) && line.incoming && line.bits
          value = line.incoming.find { |_value, label| label == from_label }&.first
          return nil if value.nil?

          return {
            expression: "#{unsigned_cast(line.bits)}((#{inline_value(value, context)}) & #{integer_mask_literal(line.bits)})",
            target: inline_register(context, line.destination)
          }
        end

        match = line.match(/\A(#{NAME})\s*=\s*phi\s+i(1|8|16|32|64)\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported phi: #{line}" unless match

        incoming = match[3].scan(/\[\s*(.+?)\s*,\s+%([-A-Za-z$._0-9]+)\s*\]/)
        value = incoming.find { |_value, label| label == from_label }&.first
        return nil if value.nil?
        bits = match[2].to_i
        {
          expression: "#{unsigned_cast(bits)}((#{inline_value(value, context)}) & #{integer_mask_literal(bits)})",
          target: inline_register(context, match[1])
        }
      end

      def simultaneous_phi_assignment_lines(assignments, spaces)
        return [] if assignments.empty?

        temp_names = assignments.map { next_phi_temp_name }
        temp_lines = assignments.zip(temp_names).map do |assignment, temp_name|
          "#{spaces}unsigned long long #{temp_name} = #{assignment.fetch(:expression)};"
        end
        assignment_lines = assignments.zip(temp_names).map do |assignment, temp_name|
          "#{spaces}#{assignment.fetch(:target)} = #{temp_name};"
        end
        temp_lines + assignment_lines
      end

      def next_phi_temp_name
        name = "pf_phi_tmp_#{@phi_temp_index}"
        @phi_temp_index += 1
        name
      end

      def llvm_value(raw)
        tokens = raw.strip.split(/\s+/)
        token = tokens.last
        return token if token.match?(/\A-?\d+\z/)
        return register(token) if token.match?(/\A#{NAME}\z/)

        raise Frontend::LLVMSubset::ParseError, "unsupported value: #{raw}"
      end

      def inline_value(raw, context)
        token = raw.strip.split(/\s+/).last
        return token if token.match?(/\A-?\d+\z/)
        return context.fetch(:values).fetch(token) if context.fetch(:values).key?(token)
        return register(token) if token.match?(/\A#{NAME}\z/)

        raise Frontend::LLVMSubset::ParseError, "unsupported value: #{raw}"
      end

      def inline_label(context, label)
        "#{context.fetch(:prefix)}_block_#{label.gsub(/[^A-Za-z0-9_]/, '_')}"
      end

      def inline_register(context, name)
        context.fetch(:values).fetch(name) do
          raise Frontend::LLVMSubset::ParseError, "unknown internal register: #{name}"
        end
      end

      def emit_puts_call(destination, raw_pointer, context: nil)
        pointer = global_string_pointer(raw_pointer, context:)
        bytes = null_terminated_bytes(pointer) + [10]
        emit_output_bytes(bytes) + return_value_assignment(destination, bytes.length, context:)
      end

      def emit_printf_call(destination, raw_pointer, context: nil)
        arguments = split_call_arguments(raw_pointer)
        pointer = global_string_pointer(pointer_argument(arguments.shift), context:)
        format_bytes = null_terminated_bytes(pointer)
        count_name = next_printf_count_name
        lines = ["    int #{count_name} = 0;"]
        lines.concat(emit_formatted_output(format_bytes, arguments, count_name, context:))
        lines.concat(return_value_assignment(destination, count_name, context:))
        lines
      end

      def emit_output_bytes(bytes)
        bytes.map do |byte|
          "    if (pf_output_cell((unsigned char)(#{byte})) != 0) PF_ABORT();"
        end
      end

      def return_value_assignment(destination, value, context:)
        return [] unless destination

        register_name = context ? inline_register(context, destination) : register(destination)
        expression = value.is_a?(Integer) ? "#{value}u" : "(unsigned int)(#{value})"
        ["    #{register_name} = #{expression};"]
      end

      def emit_formatted_output(format_bytes, typed_arguments, count_name, context:)
        lines = []
        arguments = typed_arguments.dup
        index = 0

        while index < format_bytes.length
          byte = format_bytes[index]
          if byte != 37
            lines << counted_output_line(byte, count_name)
            index += 1
            next
          end

          format = parse_printf_format(format_bytes, index)
          if format.fetch(:specifier) == 37
            if format.fetch(:length_modifier) || !format.fetch(:precision).nil?
              raise Frontend::LLVMSubset::ParseError, "unsupported printf format: #{printf_format_label(format)}"
            end

            lines.concat(emit_formatted_character(37, count_name, format))
          else
            argument = arguments.shift
            raise Frontend::LLVMSubset::ParseError, "missing printf argument for #{printf_format_label(format)}" if argument.nil?

            lines.concat(emit_printf_specifier(format.fetch(:specifier), argument, count_name, context:, format:))
          end
          index = format.fetch(:next_index)
        end

        unless arguments.empty?
          raise Frontend::LLVMSubset::ParseError, "too many printf arguments"
        end

        lines
      end

      def parse_printf_format(format_bytes, percent_index)
        cursor = percent_index + 1
        flags = []
        loop do
          case format_bytes[cursor]
          when 45
            flags << "-"
          when 48
            flags << "0"
          when 32, 35, 43
            raise Frontend::LLVMSubset::ParseError, "unsupported printf flag: #{format_bytes[cursor].chr}"
          else
            break
          end
          cursor += 1
        end

        raise Frontend::LLVMSubset::ParseError, "unsupported printf dynamic width" if format_bytes[cursor] == 42

        width, cursor = read_printf_decimal(format_bytes, cursor)
        precision = nil
        if format_bytes[cursor] == 46
          cursor += 1
          raise Frontend::LLVMSubset::ParseError, "unsupported printf dynamic precision" if format_bytes[cursor] == 42

          precision, cursor = read_printf_decimal(format_bytes, cursor)
          precision ||= 0
        end

        length_modifier = nil
        if format_bytes[cursor] == 108
          if format_bytes[cursor + 1] == 108
            length_modifier = "ll"
            cursor += 2
          else
            length_modifier = "l"
            cursor += 1
          end
        end

        specifier = format_bytes[cursor]
        raise Frontend::LLVMSubset::ParseError, "unterminated printf format specifier" if specifier.nil?

        {
          flags: flags.freeze,
          left_adjust: flags.include?("-"),
          length_modifier:,
          next_index: cursor + 1,
          precision:,
          specifier:,
          width: width || 0,
          zero_pad: flags.include?("0") && !flags.include?("-")
        }
      end

      def read_printf_decimal(format_bytes, cursor)
        start = cursor
        cursor += 1 while format_bytes[cursor]&.between?(48, 57)
        return [nil, cursor] if cursor == start

        [format_bytes[start...cursor].pack("C*").to_i, cursor]
      end

      def emit_printf_specifier(specifier, argument, count_name, context:, format:)
        length_modifier = format.fetch(:length_modifier)
        case specifier.chr
        when "d", "i"
          bits, value = typed_integer_value(argument, context:)
          output_bits = printf_integer_bits(bits, length_modifier)
          cast = signed_cast(output_bits)
          if formatted_integer_format?(format)
            return [
              "    if (pf_output_i64_formatted((long long)((#{cast})(#{value})), 10u, \"0123456789\", #{printf_width(format)}, #{printf_precision(format)}, #{printf_bool(format.fetch(:left_adjust))}, #{printf_bool(format.fetch(:zero_pad))}, &#{count_name}) != 0) PF_ABORT();"
            ]
          end

          helper = output_bits == 64 ? "pf_output_i64_decimal" : "pf_output_i32_decimal"
          ["    if (#{helper}((#{cast})(#{value}), &#{count_name}) != 0) PF_ABORT();"]
        when "u"
          bits, value = typed_integer_value(argument, context:)
          output_bits = printf_integer_bits(bits, length_modifier)
          cast = unsigned_cast(output_bits).delete_prefix("(").delete_suffix(")")
          if formatted_integer_format?(format)
            return [
              "    if (pf_output_u64_formatted((unsigned long long)((#{cast})(#{value})), 10u, \"0123456789\", #{printf_width(format)}, #{printf_precision(format)}, #{printf_bool(format.fetch(:left_adjust))}, #{printf_bool(format.fetch(:zero_pad))}, &#{count_name}) != 0) PF_ABORT();"
            ]
          end

          helper = output_bits == 64 ? "pf_output_u64_decimal" : "pf_output_u32_decimal"
          ["    if (#{helper}((#{cast})(#{value}), &#{count_name}) != 0) PF_ABORT();"]
        when "x", "X", "o"
          bits, value = typed_integer_value(argument, context:)
          output_bits = printf_integer_bits(bits, length_modifier)
          cast = unsigned_cast(output_bits).delete_prefix("(").delete_suffix(")")
          base = specifier.chr == "o" ? 8 : 16
          digits = specifier.chr == "X" ? "0123456789ABCDEF" : "0123456789abcdef"
          if formatted_integer_format?(format)
            return [
              "    if (pf_output_u64_formatted((unsigned long long)((#{cast})(#{value})), #{base}u, \"#{digits}\", #{printf_width(format)}, #{printf_precision(format)}, #{printf_bool(format.fetch(:left_adjust))}, #{printf_bool(format.fetch(:zero_pad))}, &#{count_name}) != 0) PF_ABORT();"
            ]
          end

          helper = output_bits == 64 ? "pf_output_u64_radix" : "pf_output_u32_radix"
          ["    if (#{helper}((#{cast})(#{value}), #{base}u, \"#{digits}\", &#{count_name}) != 0) PF_ABORT();"]
        when "c"
          if length_modifier
            raise Frontend::LLVMSubset::ParseError, "unsupported printf format: %#{length_modifier}#{specifier.chr}"
          end
          unless format.fetch(:precision).nil?
            raise Frontend::LLVMSubset::ParseError, "unsupported printf format: #{printf_format_label(format)}"
          end

          _bits, value = typed_integer_value(argument, context:)
          emit_formatted_character(value, count_name, format)
        when "s"
          if length_modifier
            raise Frontend::LLVMSubset::ParseError, "unsupported printf format: %#{length_modifier}#{specifier.chr}"
          end

          pointer = global_string_pointer(pointer_argument(argument), context:)
          emit_formatted_static_bytes(null_terminated_bytes(pointer), count_name, format)
        else
          raise Frontend::LLVMSubset::ParseError, "unsupported printf format: #{printf_format_label(format)}"
        end
      end

      def formatted_integer_format?(format)
        format.fetch(:width).positive? || !format.fetch(:precision).nil?
      end

      def emit_formatted_character(value, count_name, format)
        padding = [format.fetch(:width) - 1, 0].max
        lines = []
        lines.concat(counted_padding_lines(padding, count_name)) unless format.fetch(:left_adjust)
        lines << counted_output_line(value, count_name)
        lines.concat(counted_padding_lines(padding, count_name)) if format.fetch(:left_adjust)
        lines
      end

      def emit_formatted_static_bytes(bytes, count_name, format)
        selected = format.fetch(:precision).nil? ? bytes : bytes.take(format.fetch(:precision))
        padding = [format.fetch(:width) - selected.length, 0].max
        lines = []
        lines.concat(counted_padding_lines(padding, count_name)) unless format.fetch(:left_adjust)
        lines.concat(selected.map { |byte| counted_output_line(byte, count_name) })
        lines.concat(counted_padding_lines(padding, count_name)) if format.fetch(:left_adjust)
        lines
      end

      def counted_padding_lines(width, count_name)
        return [] unless width.positive?

        ["    if (pf_output_counted_padding(#{width}, &#{count_name}) != 0) PF_ABORT();"]
      end

      def printf_width(format)
        format.fetch(:width)
      end

      def printf_precision(format)
        format.fetch(:precision) || -1
      end

      def printf_bool(value)
        value ? 1 : 0
      end

      def printf_format_label(format)
        flags = format.fetch(:flags).join
        width = format.fetch(:width).positive? ? format.fetch(:width).to_s : ""
        precision = format.fetch(:precision).nil? ? "" : ".#{format.fetch(:precision)}"
        length = format.fetch(:length_modifier) || ""
        "%#{flags}#{width}#{precision}#{length}#{format.fetch(:specifier).chr}"
      end

      def printf_integer_bits(argument_bits, length_modifier)
        return 64 if length_modifier == "l" || length_modifier == "ll"
        return argument_bits if length_modifier.nil?

        raise Frontend::LLVMSubset::ParseError, "unsupported printf length modifier: #{length_modifier}"
      end

      def counted_output_line(value, count_name)
        "    if (pf_output_counted_cell((unsigned char)(#{value}), &#{count_name}) != 0) PF_ABORT();"
      end

      def next_printf_count_name
        name = "pf_printf_count_#{@printf_call_index}"
        @printf_call_index += 1
        name
      end

      def typed_integer_value(argument, context:)
        match = argument.strip.match(/\Ai(1|8|16|32|64)\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported printf integer argument: #{argument}" unless match

        [match[1].to_i, context ? inline_value(match[2], context) : llvm_value(match[2])]
      end

      def pointer_argument(argument)
        match = argument.to_s.strip.match(/\Aptr(?:\s+\w+)*\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported printf pointer argument: #{argument}" unless match

        match[1]
      end

      def split_call_arguments(raw_arguments)
        arguments = []
        current = +""
        depth = 0

        raw_arguments.each_char do |char|
          case char
          when "(", "["
            depth += 1
            current << char
          when ")", "]"
            depth -= 1
            current << char
          when ","
            if depth.zero?
              arguments << current.strip
              current.clear
            else
              current << char
            end
          else
            current << char
          end
        end

        arguments << current.strip unless current.strip.empty?
        arguments
      end

      def parsed_call(line)
        match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+(i(?:1|8|16|32|64)|void)\s+(?:\([^)]*\)\s+)?@([-A-Za-z$._0-9]+)\((.*)\)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported call: #{line}" unless match

        {
          destination: match[1],
          function_name: match[3],
          raw_arguments: match[4],
          return_type: match[2]
        }
      end

      def parse_typed_call_arguments(raw)
        split_call_arguments(raw).map do |argument|
          stripped = argument.strip
          if (match = stripped.match(/\A(i(?:1|8|16|32|64))\s+(.+)\z/))
            next({ type: match[1], value: match[2] })
          end
          if (match = stripped.match(/\Aptr(?:\s+\w+)*\s+(.+)\z/))
            next({ type: "ptr", value: match[1] })
          end

          raise Frontend::LLVMSubset::ParseError, "unsupported call argument: #{argument}"
        end
      end

      def validate_call_signature!(call, line)
        return validate_memory_intrinsic_signature!(call) if llvm_memory_intrinsic?(call.fetch(:function_name))

        signature = function_signature(call.fetch(:function_name))
        unless signature
          raise Frontend::LLVMSubset::ParseError, "unknown function: @#{call.fetch(:function_name)}"
        end
        unless call.fetch(:return_type) == signature.fetch(:return_type)
          raise Frontend::LLVMSubset::ParseError, "call return type mismatch for @#{call.fetch(:function_name)}: expected #{signature.fetch(:return_type)}, got #{call.fetch(:return_type)}"
        end

        arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
        parameter_types = signature.fetch(:parameter_types)
        if signature.fetch(:varargs)
          if arguments.length < parameter_types.length
            raise Frontend::LLVMSubset::ParseError, "wrong argument count for @#{call.fetch(:function_name)}: expected at least #{parameter_types.length}, got #{arguments.length}"
          end
        elsif arguments.length != parameter_types.length
          raise Frontend::LLVMSubset::ParseError, "wrong argument count for @#{call.fetch(:function_name)}: expected #{parameter_types.length}, got #{arguments.length}"
        end

        parameter_types.each_with_index do |type, index|
          actual = arguments.fetch(index).fetch(:type)
          next if type == actual

          raise Frontend::LLVMSubset::ParseError, "call argument #{index + 1} type mismatch for @#{call.fetch(:function_name)}: expected #{type}, got #{actual}"
        end
      rescue Frontend::LLVMSubset::ParseError => e
        raise e if e.message.start_with?("line ")

        line_number = source_line_number(line)
        prefix = line_number ? "line #{line_number}: " : ""
        raise Frontend::LLVMSubset::ParseError, "#{prefix}#{e.message}"
      end

      def function_signature(name)
        function_signatures[name] || BUILTIN_FUNCTION_SIGNATURES[name]
      end

      def llvm_memory_intrinsic?(name)
        llvm_memset_intrinsic?(name) || llvm_memcpy_intrinsic?(name) || llvm_memmove_intrinsic?(name)
      end

      def llvm_memset_intrinsic?(name)
        name.start_with?("llvm.memset.")
      end

      def llvm_memcpy_intrinsic?(name)
        name.start_with?("llvm.memcpy.")
      end

      def llvm_memmove_intrinsic?(name)
        name.start_with?("llvm.memmove.")
      end

      def validate_memory_intrinsic_signature!(call)
        name = call.fetch(:function_name)
        unless call.fetch(:return_type) == "void"
          raise Frontend::LLVMSubset::ParseError, "call return type mismatch for @#{name}: expected void, got #{call.fetch(:return_type)}"
        end
        if call.fetch(:destination)
          raise Frontend::LLVMSubset::ParseError, "void call cannot assign a result: @#{name}"
        end

        arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
        if llvm_memset_intrinsic?(name)
          validate_memory_intrinsic_arguments!(name, arguments, ["ptr", "i8", %w[i32 i64], "i1"])
          return
        end

        validate_memory_intrinsic_arguments!(name, arguments, ["ptr", "ptr", %w[i32 i64], "i1"])
      end

      def validate_memory_intrinsic_arguments!(name, arguments, expected_types)
        if arguments.length != expected_types.length
          raise Frontend::LLVMSubset::ParseError, "wrong argument count for @#{name}: expected #{expected_types.length}, got #{arguments.length}"
        end

        expected_types.each_with_index do |expected, index|
          actual = arguments.fetch(index).fetch(:type)
          next if Array(expected).include?(actual)

          expected_description = Array(expected).join(" or ")
          raise Frontend::LLVMSubset::ParseError, "call argument #{index + 1} type mismatch for @#{name}: expected #{expected_description}, got #{actual}"
        end
      end

      def emit_memory_intrinsic_call(call, context: nil)
        arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
        if llvm_memset_intrinsic?(call.fetch(:function_name))
          return emit_memset_intrinsic(arguments, context:)
        end
        if llvm_memmove_intrinsic?(call.fetch(:function_name))
          return emit_memmove_intrinsic(arguments, context:)
        end

        emit_memcpy_intrinsic(arguments, context:)
      end

      def emit_memset_intrinsic(arguments, context:)
        prefix = next_memory_intrinsic_prefix
        destination = memory_address(arguments.fetch(0).fetch(:value), context:)
        ensure_writable_address!(destination)
        byte_value = scalar_value(arguments.fetch(1).fetch(:value), context:)
        length = scalar_value(arguments.fetch(2).fetch(:value), context:)
        [
          "    {",
          "        long long #{prefix}_dst = (long long)(#{destination.offset});",
          "        long long #{prefix}_len = (long long)(#{length});",
          "        long long #{prefix}_offset = 0;",
          "        unsigned char #{prefix}_value = (unsigned char)(#{byte_value});",
          "        if (#{prefix}_dst < 0 || #{prefix}_len < 0 || #{prefix}_dst + #{prefix}_len > #{destination.limit}) {",
          "            fprintf(stderr, \"pfc runtime error: LLVM memory intrinsic out of range\\n\");",
          "            PF_ABORT();",
          "        }",
          "        for (#{prefix}_offset = 0; #{prefix}_offset < #{prefix}_len; #{prefix}_offset++) {",
          "            #{destination.memory}[#{prefix}_dst + #{prefix}_offset] = #{prefix}_value;",
          "        }",
          "    }"
        ]
      end

      def emit_memcpy_intrinsic(arguments, context:)
        prefix = next_memory_intrinsic_prefix
        destination = memory_address(arguments.fetch(0).fetch(:value), context:)
        ensure_writable_address!(destination)
        source = memory_address(arguments.fetch(1).fetch(:value), context:)
        length = scalar_value(arguments.fetch(2).fetch(:value), context:)
        [
          "    {",
          "        long long #{prefix}_dst = (long long)(#{destination.offset});",
          "        long long #{prefix}_src = (long long)(#{source.offset});",
          "        long long #{prefix}_len = (long long)(#{length});",
          "        long long #{prefix}_offset = 0;",
          "        if (#{prefix}_dst < 0 || #{prefix}_src < 0 || #{prefix}_len < 0 || #{prefix}_dst + #{prefix}_len > #{destination.limit} || #{prefix}_src + #{prefix}_len > #{source.limit}) {",
          "            fprintf(stderr, \"pfc runtime error: LLVM memory intrinsic out of range\\n\");",
          "            PF_ABORT();",
          "        }",
          "        for (#{prefix}_offset = 0; #{prefix}_offset < #{prefix}_len; #{prefix}_offset++) {",
          "            #{destination.memory}[#{prefix}_dst + #{prefix}_offset] = #{source.memory}[#{prefix}_src + #{prefix}_offset];",
          "        }",
          "    }"
        ]
      end

      def emit_memmove_intrinsic(arguments, context:)
        prefix = next_memory_intrinsic_prefix
        destination = memory_address(arguments.fetch(0).fetch(:value), context:)
        ensure_writable_address!(destination)
        source = memory_address(arguments.fetch(1).fetch(:value), context:)
        length = scalar_value(arguments.fetch(2).fetch(:value), context:)
        lines = [
          "    {",
          "        long long #{prefix}_dst = (long long)(#{destination.offset});",
          "        long long #{prefix}_src = (long long)(#{source.offset});",
          "        long long #{prefix}_len = (long long)(#{length});",
          "        long long #{prefix}_offset = 0;",
          "        if (#{prefix}_dst < 0 || #{prefix}_src < 0 || #{prefix}_len < 0 || #{prefix}_dst + #{prefix}_len > #{destination.limit} || #{prefix}_src + #{prefix}_len > #{source.limit}) {",
          "            fprintf(stderr, \"pfc runtime error: LLVM memory intrinsic out of range\\n\");",
          "            PF_ABORT();",
          "        }"
        ]
        if destination.memory == source.memory
          lines.concat([
            "        if (#{prefix}_dst > #{prefix}_src && #{prefix}_dst < #{prefix}_src + #{prefix}_len) {",
            "            for (#{prefix}_offset = #{prefix}_len; #{prefix}_offset > 0; #{prefix}_offset--) {",
            "                #{destination.memory}[#{prefix}_dst + #{prefix}_offset - 1] = #{source.memory}[#{prefix}_src + #{prefix}_offset - 1];",
            "            }",
            "        } else {",
            "            for (#{prefix}_offset = 0; #{prefix}_offset < #{prefix}_len; #{prefix}_offset++) {",
            "                #{destination.memory}[#{prefix}_dst + #{prefix}_offset] = #{source.memory}[#{prefix}_src + #{prefix}_offset];",
            "            }",
            "        }"
          ])
        else
          lines.concat([
            "        for (#{prefix}_offset = 0; #{prefix}_offset < #{prefix}_len; #{prefix}_offset++) {",
            "            #{destination.memory}[#{prefix}_dst + #{prefix}_offset] = #{source.memory}[#{prefix}_src + #{prefix}_offset];",
            "        }"
          ])
        end
        lines << "    }"
        lines
      end

      def next_memory_intrinsic_prefix
        name = "pf_mem_#{@memory_intrinsic_index}"
        @memory_intrinsic_index += 1
        name
      end

      def scalar_value(raw, context:)
        context ? inline_value(raw, context) : llvm_value(raw)
      end

      def validate_builtin_declarations!
        BUILTIN_FUNCTION_SIGNATURES.each do |name, expected|
          declared = function_signatures[name]
          next unless declared
          next if same_function_signature?(declared, expected)

          raise Frontend::LLVMSubset::ParseError, "unsupported declaration for @#{name}: expected #{function_signature_description(expected)}"
        end
      end

      def same_function_signature?(left, right)
        left.fetch(:return_type) == right.fetch(:return_type) &&
          left.fetch(:parameter_types) == right.fetch(:parameter_types) &&
          left.fetch(:varargs) == right.fetch(:varargs)
      end

      def function_signature_description(signature)
        parameters = signature.fetch(:parameter_types).dup
        parameters << "..." if signature.fetch(:varargs)
        "#{signature.fetch(:return_type)}(#{parameters.join(', ')})"
      end

      def global_string_pointer(raw_pointer, context:)
        direct = global_string_pointer_literal(raw_pointer)
        return direct if direct

        token = raw_pointer.strip.split(/\s+/).last
        pointer = if context && context.fetch(:pointers).key?(token)
                    context.fetch(:pointers).fetch(token)
                  elsif pointers.key?(token)
                    pointers.fetch(token)
                  end
        return pointer if pointer.is_a?(GlobalStringPointer)

        raise Frontend::LLVMSubset::ParseError, "unsupported string pointer: #{raw_pointer}"
      end

      def global_string_pointer_literal(raw_pointer)
        if (match = raw_pointer.match(/getelementptr(?:\s+inbounds)?\s*\(\[(\d+)\s+x\s+i8\],\s+ptr\s+(#{GLOBAL_NAME}),\s+i\d+\s+(-?\d+),\s+i\d+\s+(-?\d+)\)/))
          return GlobalStringPointer.new(
            name: match[2],
            offset: (match[3].to_i * match[1].to_i) + match[4].to_i
          )
        end

        match = raw_pointer.match(/(?:\A|\s)(#{GLOBAL_NAME})\z/)
        return nil unless match

        GlobalStringPointer.new(name: match[1], offset: 0)
      end

      def null_terminated_bytes(pointer)
        bytes = global_strings.fetch(pointer.name) do
          raise Frontend::LLVMSubset::ParseError, "unknown global string: #{pointer.name}"
        end
        selected = bytes.drop(pointer.offset)
        terminator = selected.index(0)
        terminator ? selected.take(terminator) : selected
      end

      def with_statement_context(line)
        yield
      rescue Frontend::LLVMSubset::ParseError => e
        raise e if e.message.start_with?("line ")

        line_number = source_line_number(line)
        prefix = line_number ? "line #{line_number}: " : ""
        raise Frontend::LLVMSubset::ParseError, "#{prefix}#{e.message}"
      end

      def source_line_number(line)
        @source_line_numbers.fetch(instruction_text(line), nil)
      end

      def instruction_text(instruction)
        instruction.respond_to?(:text) ? instruction.text : instruction.to_s
      end

      def instruction_kind(instruction)
        instruction.respond_to?(:kind) ? instruction.kind : nil
      end

      def inline_pointer_expr(context, name)
        memory_address(name, context:).offset
      end

      def pointer_expr(name)
        memory_address(name).offset
      end

      def memory_address(name, context: nil)
        pointer = resolve_pointer(name, context:)
        if pointer.is_a?(GlobalStringPointer)
          raise Frontend::LLVMSubset::ParseError, "global string pointer is only supported for puts/printf: #{name}"
        end
        if pointer.is_a?(GlobalMemoryPointer)
          return MemoryAddress.new(
            limit: "PF_LLVM_GLOBAL_MEMORY_SIZE",
            memory: "llvm_global_memory",
            name: pointer.name,
            readonly: !global_numeric_mutability.fetch(pointer.name, false),
            offset: pointer.offset
          )
        end

        MemoryAddress.new(limit: "PF_LLVM_MEMORY_SIZE", memory: "llvm_memory", offset: pointer, readonly: false)
      end

      def resolve_pointer(name, context:)
        token = name.to_s.strip.split(/\s+/).last
        if context && context.fetch(:pointers).key?(token)
          return context.fetch(:pointers).fetch(token)
        end

        pointers.fetch(token) { raise Frontend::LLVMSubset::ParseError, "unknown pointer: #{token}" }
      end

      def pointer_from_address(address, offset)
        if address.memory == "llvm_global_memory"
          GlobalMemoryPointer.new(name: address.name, offset:)
        else
          offset
        end
      end

      def ensure_writable_address!(address)
        return unless address.readonly

        raise Frontend::LLVMSubset::ParseError, "cannot write to constant global: #{address.name}"
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

      def byte_width(bits)
        [(bits + 7) / 8, 1].max
      end

      def integer_mask_literal(bits)
        "#{integer_mask(bits)}#{integer_suffix(bits)}"
      end

      def integer_suffix(bits)
        bits == 64 ? "ull" : "u"
      end

      def unsigned_cast(bits)
        bits == 64 ? "(unsigned long long)" : "(unsigned int)"
      end

      def signed_cast(bits)
        bits == 64 ? "long long" : "int"
      end

      def sign_bit_literal(bits)
        "#{1 << (bits - 1)}#{integer_suffix(bits)}"
      end

      def slot_lines(address, width)
        [
          "    pf_slot_index = (int)(#{address.offset});",
          "    if (pf_slot_index < 0 || pf_slot_index + #{width} > #{address.limit}) {",
          "        fprintf(stderr, \"pfc runtime error: LLVM memory access out of range: %d\\n\", pf_slot_index);",
          "        PF_ABORT();",
          "    }"
        ]
      end

      def inline_slot_lines(address, width)
        [
          "    pf_slot_index = (int)(#{address.offset});",
          "    if (pf_slot_index < 0 || pf_slot_index + #{width} > #{address.limit}) {",
          "        fprintf(stderr, \"pfc runtime error: LLVM memory access out of range: %d\\n\", pf_slot_index);",
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
        when "ashr" then "#{unsigned_cast(bits)}((#{signed_expression(left, bits)}) >> (#{right}))"
        end
      end

      def cast_expression(operator, from_bits, to_bits, value)
        expression = operator == "sext" ? signed_expression(value, from_bits) : value
        "#{unsigned_cast(to_bits)}((#{expression}) & #{integer_mask_literal(to_bits)})"
      end

      def signed_expression(value, bits)
        "((#{signed_cast(bits)})(((#{value}) & #{sign_bit_literal(bits)}) ? ((#{value}) | ~#{integer_mask_literal(bits)}) : ((#{value}) & #{integer_mask_literal(bits)})))"
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
