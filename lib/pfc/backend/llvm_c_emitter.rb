# frozen_string_literal: true

require_relative "c_emitter"
require_relative "llvm_c_emitter/aggregate_values"
require_relative "llvm_c_emitter/intrinsics"
require_relative "llvm_c_emitter/pointer_memory"
require_relative "llvm_c_emitter/source_locations"
require_relative "llvm_c_emitter/type_layout"
require_relative "printf_primitives"
require_relative "../frontend/llvm_subset"
require_relative "../frontend/llvm_subset/parser"

module PFC
  module Backend
    class LLVMCEmitter
      include AggregateValues
      include Intrinsics
      include PointerMemory
      include SourceLocations
      include TypeLayout

      DEFAULT_TAPE_SIZE = CEmitter::DEFAULT_TAPE_SIZE
      NAME = /%[-A-Za-z$._0-9]+/
      GLOBAL_NAME = /@[-A-Za-z$._0-9]+/
      POINTER_NAME = /(?:#{NAME}|#{GLOBAL_NAME})/
      ATTRIBUTE_TOKEN = /[-\w]+(?:\([^)]*\))?/
      GlobalStringPointer = Struct.new(:name, :offset, keyword_init: true)
      GlobalMemoryPointer = Struct.new(:name, :offset, keyword_init: true)
      EncodedPointer = Struct.new(:value, keyword_init: true)
      MemoryAddress = Struct.new(:invalid_expression, :limit, :memory, :name, :offset, :readonly, :readonly_expression, keyword_init: true)
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
        @target_datalayout = parsed.fetch(:target_datalayout)
        @global_numeric_data = parsed.fetch(:global_numeric_data)
        @global_numeric_mutability = parsed.fetch(:global_numeric_mutability)
        @global_strings = parsed.fetch(:global_strings)
        @global_string_offsets = build_global_string_offsets
        @global_string_bytes = build_global_string_memory
        @struct_types = parsed.fetch(:struct_types)
        @struct_packed_types = parsed.fetch(:struct_packed_types, {})
        @internal_functions = parsed.fetch(:internal_functions)
        @blocks = parsed.fetch(:blocks)
        @block_order = parsed.fetch(:block_order)
        @source_line_numbers = parsed.fetch(:source_line_numbers)
        @slots = {}
        @slot_count = 0
        @pointers = {}
        @global_numeric_offsets, raw_global_numeric_bytes = build_global_numeric_layout
        @aggregate_registers = {}
        @i128_high_registers = {}
        @registers = {}
        @aggregate_copy_index = 0
        @inline_call_index = 0
        @memory_intrinsic_index = 0
        @printf_call_index = 0
        @printf_format_index = 0
        @phi_temp_index = 0
        validate_tape_size!
        validate_builtin_declarations!
        analyze_global_numeric_pointers
        analyze_global_aliases
        @global_numeric_bytes = apply_global_numeric_relocations(raw_global_numeric_bytes)
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

      attr_reader :aggregate_registers, :blocks, :block_order, :function_signatures, :global_numeric_bytes, :global_numeric_data, :global_numeric_mutability, :global_numeric_offsets, :global_string_bytes, :global_string_offsets, :global_strings, :i128_high_registers, :internal_functions, :pointers, :registers, :slot_count, :source, :struct_packed_types, :struct_types, :target_datalayout, :tape_size

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

      def apply_global_numeric_relocations(bytes)
        output = bytes.dup
        global_numeric_relocations.each do |relocation|
          base = global_numeric_offsets.fetch(relocation.fetch(:global))
          encoded = relocation.fetch(:encoded)
          relocation.fetch(:width).times do |index|
            output[base + relocation.fetch(:offset) + index] = "(((#{encoded}) >> #{index * 8}) & 255ull)"
          end
        end
        output
      end

      def global_numeric_relocations
        source.each_line.flat_map do |line|
          stripped = line.sub(/;.*/, "").strip
          next [] if stripped.empty?

          if (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(?:global|constant)\s+ptr\s+(.+?)(?:,\s+align\s+\d+)?\z/))
            next global_pointer_initializer_relocations(match[1], "ptr", match[2], 0)
          end
          if (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(?:global|constant)\s+i(1|8|16|32|64)\s+ptrtoint\s*\(ptr\s+(.+?)\s+to\s+i\2\)(?:,\s+align\s+\d+)?\z/))
            next global_pointer_initializer_relocations(match[1], "i#{match[2]}", match[3], 0)
          end
          if (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(?:global|constant)\s+(.+?)\s+(\{.*\}|\[.*\]|zeroinitializer)(?:,\s+align\s+\d+)?\z/))
            next collect_global_initializer_relocations(match[1], match[2], match[3], 0)
          end

          []
        end
      end

      def collect_global_initializer_relocations(global, type, initializer, base_offset)
        return [] if initializer == "zeroinitializer"

        values = initializer.delete_prefix("{").delete_prefix("[").delete_suffix("}").delete_suffix("]")
        elements = Frontend::LLVMSubset::Parser::Instruction.split_arguments(values)
        fields = aggregate_fields(type)
        offsets = aggregate_field_offsets(type)
        fields.zip(elements).flat_map.with_index do |(field_type, element), index|
          element_type, element_value = split_typed_initializer(element, field_type)
          offset = base_offset + offsets.fetch(index)
          if pointer_type_name?(element_type)
            global_pointer_initializer_relocations(global, element_type, element_value, offset)
          elsif integer_type?(element_type) && element_value.match?(/\Aptrtoint\s*\(ptr\s+(.+?)\s+to\s+#{Regexp.escape(element_type)}\)\z/)
            global_pointer_initializer_relocations(global, element_type, Regexp.last_match(1), offset)
          elsif aggregate_type?(element_type)
            collect_global_initializer_relocations(global, element_type, element_value, offset)
          else
            []
          end
        end
      end

      def global_pointer_initializer_relocations(global, type, value, offset)
        stripped = strip_value_attributes(value)
        return [] if %w[null zeroinitializer undef poison].include?(stripped)
        return [] if stripped.match?(/\Ainttoptr\s*\(i(?:1|8|16|32|64)\s+0\s+to\s+ptr\)\z/)

        encoded = if (match = stripped.match(/\Ainttoptr\s*\(i(?:1|8|16|32|64)\s+(-?\d+)\s+to\s+ptr\)\z/))
                    match[1]
                  else
                    encoded_pointer_value(stripped)
                  end
        width = integer_type?(type) ? byte_width(type.delete_prefix("i").to_i) : pointer_size
        [{ global:, offset:, width:, encoded: }]
      end

      def build_global_string_offsets
        offset = 0
        global_strings.each_with_object({}) do |(name, bytes), offsets|
          offsets[name] = offset
          offset += bytes.length + 1
        end
      end

      def build_global_string_memory
        global_strings.values.flat_map { |bytes| bytes + [0] }
      end

      def analyze_global_numeric_pointers
        global_numeric_offsets.each do |name, offset|
          pointers[name] = GlobalMemoryPointer.new(name:, offset:)
        end
      end

      def analyze_global_aliases
        source.each_line do |line|
          stripped = line.sub(/;.*/, "").strip
          match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\balias\s+.+?,\s+(?:ptr|.+?\*)\s+(.+)\z/)
          next unless match

          pointers[match[1]] = pointer_binding(match[2])
        end
      end

      def analyze_allocations
        all_lines.each do |line|
          if (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+\[(\d+)\s+x\s+i(1|8|16|32|64)\](?:,\s+align\s+\d+)?\z/))
            allocate_pointer(match[1], match[2].to_i * byte_width(match[3].to_i))
          elsif (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+(.+?)(?:,\s+i(?:32|64)\s+(.+?))?(?:,\s+align\s+\d+)?\z/))
            allocate_pointer(match[1], alloca_width(match[2], match[3]))
          elsif (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+i(1|8|16|32|64)(?:,\s+align\s+\d+)?\z/))
            allocate_pointer(match[1], byte_width(match[2].to_i))
          end
        end

        internal_functions.each_value do |function|
          function.fetch(:blocks).values.flatten.each do |line|
            if (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+\[(\d+)\s+x\s+i(1|8|16|32|64)\](?:,\s+align\s+\d+)?\z/))
              function.fetch(:allocations)[match[1]] = allocate_slots(match[2].to_i * byte_width(match[3].to_i))
            elsif (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+(.+?)(?:,\s+i(?:32|64)\s+(.+?))?(?:,\s+align\s+\d+)?\z/))
              function.fetch(:allocations)[match[1]] = allocate_slots(alloca_width(match[2], match[3]))
            elsif (match = line.match(/\A(#{NAME})\s*=\s*alloca\s+i(1|8|16|32|64)(?:,\s+align\s+\d+)?\z/))
              function.fetch(:allocations)[match[1]] = allocate_slots(byte_width(match[2].to_i))
            end
          end
        end
      end

      def analyze_registers
        all_lines.each do |line|
          lhs = line[/\A(#{NAME})\s*=/, 1]
          lhs = line.destination if lhs.nil? && line.respond_to?(:destination)
          next if lhs.nil?
          next if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*alloca\b/)
          next if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*getelementptr\b/)
          next if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*inttoptr\b/)
          next if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*bitcast\s+(?:ptr|.+?\*)\b/)
          next if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*select\s+i1\s+.+?,\s+ptr\b/)
          pointer_result = line.respond_to?(:value_type) && line.value_type == "ptr" && line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*(?:load|extractvalue|freeze)\b/)
          if (match = line.match(/\A#{Regexp.escape(lhs)}\s*=\s*(?:load|insertvalue|insertelement)\s+(.+?)(?:,|\s+)/)) && aggregate_type?(match[1])
            aggregate_registers[lhs] = { name: c_aggregate_name(lhs), size: type_size(match[1]), type: match[1] }
            next
          end
          if line.respond_to?(:destination) && line.respond_to?(:value_type) && line.destination == lhs && aggregate_type?(line.value_type)
            aggregate_registers[lhs] = { name: c_aggregate_name(lhs), size: type_size(line.value_type), type: line.value_type }
            next
          end
          if line.respond_to?(:destination) && line.respond_to?(:vector_type) && line.destination == lhs && aggregate_type?(line.vector_type) &&
             (line.respond_to?(:value) || line.respond_to?(:operator) || line.respond_to?(:predicate) || line.respond_to?(:true_value))
            aggregate_registers[lhs] = { name: c_aggregate_name(lhs), size: type_size(line.vector_type), type: line.vector_type }
            next
          end

          if line.respond_to?(:destination) && line.respond_to?(:return_type) && line.destination == lhs && aggregate_type?(line.return_type)
            aggregate_registers[lhs] = { name: c_aggregate_name(lhs), size: type_size(line.return_type), type: line.return_type }
            next
          end

          registers[lhs] = c_value_name(lhs)
          i128_high_registers[lhs] = "#{c_value_name(lhs)}_hi" if (line.respond_to?(:bits) && line.bits == 128) || (line.respond_to?(:to_bits) && line.to_bits == 128) || (line.respond_to?(:return_type) && line.return_type == "i128")
          pointers[lhs] = EncodedPointer.new(value: registers.fetch(lhs)) if pointer_result || line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*phi\s+(?:ptr|.+?\*)\b/)
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

      def alloca_width(raw_type, raw_count)
        count = if raw_count.nil?
                  1
                elsif raw_count.match?(/\A-?\d+\z/)
                  raw_count.to_i
                else
                  tape_size
                end
        [type_size(raw_type) * count, 1].max
      end

      def type_size(raw_type)
        type = raw_type.strip
        return byte_width(Regexp.last_match(1).to_i) if type.match(/\Ai(1|8|16|32|64)\z/)
        return 16 if type == "i128"
        return pointer_size if pointer_type_name?(type)
        if type.match(/\A\[(\d+)\s+x\s+(.+)\]\z/)
          count = Regexp.last_match(1).to_i
          element = Regexp.last_match(2)
          return type_size(element) * count
        end
        if type.match(/\A<(\d+)\s+x\s+(i(?:1|8|16|32|64))>\z/)
          count = Regexp.last_match(1).to_i
          element = Regexp.last_match(2)
          return type_size(element) * count
        end
        return struct_layout(type).fetch(:size) if struct_type?(type)
        raise Frontend::LLVMSubset::ParseError, "unsupported LLVM type: #{raw_type}"
      end

      def pointer_size
        return 8 unless target_datalayout

        match = target_datalayout.match(/(?:\A|-)p(?::\d+)?:([0-9]+)/)
        match ? byte_width(match[1].to_i) : 8
      end

      def pointer_align
        return pointer_size unless target_datalayout

        match = target_datalayout.match(/(?:\A|-)p(?::\d+)?:\d+:([0-9]+)/)
        match ? byte_width(match[1].to_i) : pointer_size
      end

      def integer_align(bits)
        match = target_datalayout&.match(/(?:\A|-)i#{bits}:([0-9]+)/)
        match ? byte_width(match[1].to_i) : byte_width(bits)
      end

      def type_align(raw_type)
        type = raw_type.strip
        return integer_align(Regexp.last_match(1).to_i) if type.match(/\Ai(1|8|16|32|64|128)\z/)
        return pointer_align if pointer_type_name?(type)
        return type_align(Regexp.last_match(2)) if type.match(/\A\[(\d+)\s+x\s+(.+)\]\z/)
        return type_align(Regexp.last_match(2)) if type.match(/\A<(\d+)\s+x\s+(.+)>\z/)
        return struct_layout(type).fetch(:align) if struct_type?(type)
        1
      end

      def struct_type?(type)
        struct_types.key?(type.strip) || type.strip.match?(/\A(?:<)?\{.*\}(?:>)?\z/)
      end

      def struct_fields(type)
        stripped = type.strip
        return struct_types.fetch(stripped) if struct_types.key?(stripped)

        stripped.delete_prefix("<").delete_prefix("{").delete_suffix(">").delete_suffix("}").then do |fields|
          Frontend::LLVMSubset::Parser::Instruction.split_arguments(fields)
        end
      end

      def struct_layout(type)
        @struct_layout_cache ||= {}
        key = type.strip
        return @struct_layout_cache.fetch(key) if @struct_layout_cache.key?(key)

        offset = 0
        align = 1
        field_offsets = []
        packed = packed_struct_type?(key)
        fields = struct_fields(key)
        fields.each do |field|
          field_align = packed ? 1 : type_align(field)
          offset = align_to(offset, field_align)
          field_offsets << offset
          offset += type_size(field)
          align = [align, field_align].max
        end
        @struct_layout_cache[key] = {
          align:,
          field_offsets:,
          fields:,
          size: packed ? offset : align_to(offset, align)
        }
      end

      def packed_struct_type?(type)
        stripped = type.strip
        stripped.start_with?("<{") || struct_packed_types.fetch(stripped, false)
      end

      def align_to(value, alignment)
        return value if alignment <= 1

        ((value + alignment - 1) / alignment) * alignment
      end

      def pointer_type_name?(type)
        stripped = type.to_s.strip
        stripped == "ptr" || stripped.start_with?("ptr addrspace(") || stripped.end_with?("*")
      end

      def zero_addrspace_pointer_type?(type)
        stripped = type.to_s.strip
        return true if stripped == "ptr" || stripped.end_with?("*")
        return Regexp.last_match(1).to_i.zero? if stripped.match(/\Aptr\s+addrspace\((\d+)\)\z/)

        false
      end

      def integer_type?(type)
        type.to_s.match?(/\Ai(?:1|8|16|32|64)\z/)
      end

      def aggregate_field_offsets(type)
        stripped = type.strip
        if stripped.match(/\A\[(\d+)\s+x\s+(.+)\]\z/)
          count = Regexp.last_match(1).to_i
          element = Regexp.last_match(2)
          element_size = type_size(element)
          return Array.new(count) { |index| index * element_size }
        end
        if stripped.match(/\A<(\d+)\s+x\s+(i(?:1|8|16|32|64))>\z/)
          count = Regexp.last_match(1).to_i
          element_size = type_size(Regexp.last_match(2))
          return Array.new(count) { |index| index * element_size }
        end
        return struct_layout(stripped).fetch(:field_offsets) if struct_type?(stripped)

        offset = 0
        struct_fields(stripped).map do |field|
          current = offset
          offset += type_size(field)
          current
        end
      end

      def split_typed_initializer(element, expected_type)
        stripped = element.strip
        expected = expected_type.strip
        if stripped.start_with?("#{expected} ")
          return [expected, stripped.delete_prefix("#{expected} ").strip]
        end

        match = stripped.match(/\A(.+?)\s+(.+)\z/)
        raise Frontend::LLVMSubset::ParseError, "unsupported aggregate element: #{element}" unless match

        [pointer_type_name?(match[1]) ? "ptr" : match[1], match[2]]
      end

      def gep_offset_expression(source_type, indices, base_offset, context: nil)
        offset = base_offset
        current_type = source_type.strip
        indices.each_with_index do |raw_index, index_position|
          value = context ? inline_value(raw_index, context) : llvm_value(raw_index)
          if index_position.zero?
            offset = "((#{offset}) + ((#{value}) * #{type_size(current_type)}))"
            next
          end

          if current_type.match(/\A\[(\d+)\s+x\s+(.+)\]\z/)
            element_type = Regexp.last_match(2)
            offset = "((#{offset}) + ((#{value}) * #{type_size(element_type)}))"
            current_type = element_type
          elsif struct_type?(current_type)
            field_index = raw_index.to_i
            layout = struct_layout(current_type)
            raise Frontend::LLVMSubset::ParseError, "dynamic struct getelementptr index is unsupported: #{raw_index}" unless raw_index.match?(/\A-?\d+\z/)

            offset = "((#{offset}) + #{layout.fetch(:field_offsets).fetch(field_index)})"
            current_type = layout.fetch(:fields).fetch(field_index)
          else
            offset = "((#{offset}) + ((#{value}) * #{type_size(current_type)}))"
          end
        end
        offset
      end

      def aggregate_type?(type)
        stripped = type.to_s.strip
        struct_type?(stripped) || stripped.match?(/\A\[\d+\s+x\s+.+\]\z/) || stripped.match?(/\A<\d+\s+x\s+i(?:1|8|16|32|64)>\z/)
      end

      def aggregate_fields(type)
        stripped = type.strip
        if stripped.match(/\A\[(\d+)\s+x\s+(.+)\]\z/)
          return Array.new(Regexp.last_match(1).to_i, Regexp.last_match(2))
        end
        if stripped.match(/\A<(\d+)\s+x\s+(i(?:1|8|16|32|64))>\z/)
          return Array.new(Regexp.last_match(1).to_i, Regexp.last_match(2))
        end

        struct_fields(stripped)
      end

      def aggregate_register(name, context: nil)
        aggregate_map = context ? context.fetch(:aggregates) : aggregate_registers
        aggregate_map.fetch(name) do
          raise Frontend::LLVMSubset::ParseError, "unknown aggregate register: #{name}"
        end
      end

      def aggregate_index_info(type, indices)
        offset = 0
        current_type = type.strip
        indices.each do |index|
          if current_type.match(/\A\[(\d+)\s+x\s+(.+)\]\z/)
            current_type = Regexp.last_match(2)
            offset += index * type_size(current_type)
          elsif current_type.match(/\A<(\d+)\s+x\s+(i(?:1|8|16|32|64))>\z/)
            current_type = Regexp.last_match(2)
            offset += index * type_size(current_type)
          elsif struct_type?(current_type)
            layout = struct_layout(current_type)
            offset += layout.fetch(:field_offsets).fetch(index)
            current_type = layout.fetch(:fields).fetch(index)
          else
            raise Frontend::LLVMSubset::ParseError, "unsupported aggregate index into #{current_type}"
          end
        end
        [offset, current_type]
      end

      def aggregate_value_bytes(value, value_type, context: nil)
        aggregate_map = context ? context.fetch(:aggregates) : aggregate_registers
        return aggregate_register(value, context:).fetch(:name) if aggregate_map.key?(value)
        constant = aggregate_constant_bytes(value, value_type)
        return byte_array_literal(constant) if constant
        return nil if %w[zeroinitializer undef poison].include?(value)

        raise Frontend::LLVMSubset::ParseError, "unsupported aggregate value: #{value}"
      end

      def aggregate_constant_bytes(value, value_type)
        stripped_value = value.to_s.strip
        stripped_type = value_type.to_s.strip
        return Array.new(type_size(stripped_type), 0) if %w[zeroinitializer undef poison].include?(stripped_value)
        return nil unless stripped_type.match(/\A<(\d+)\s+x\s+i(1|8|16|32|64)>\z/)
        return nil unless stripped_value.start_with?("<") && stripped_value.end_with?(">")

        count = Regexp.last_match(1).to_i
        bits = Regexp.last_match(2).to_i
        elements = Frontend::LLVMSubset::Parser::Instruction.split_arguments(stripped_value[1...-1])
        if elements.length != count
          raise Frontend::LLVMSubset::ParseError, "vector literal has #{elements.length} elements, expected #{count}"
        end

        elements.flat_map do |element|
          match = element.match(/\Ai#{bits}\s+(-?\d+|zeroinitializer|undef|poison)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported vector literal element: #{element}" unless match

          integer_literal_bytes(match[1], bits)
        end
      end

      def integer_literal_bytes(raw_value, bits)
        value = %w[zeroinitializer undef poison].include?(raw_value) ? 0 : raw_value.to_i
        unsigned_value = value & integer_mask(bits)
        Array.new(byte_width(bits)) do |offset|
          (unsigned_value >> (offset * 8)) & 255
        end
      end

      def byte_array_literal(bytes)
        "(unsigned char[]){#{bytes.map { |byte| "#{byte}u" }.join(', ')}}"
      end

      def next_aggregate_copy_prefix
        name = "pf_agg_#{@aggregate_copy_index}"
        @aggregate_copy_index += 1
        name
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
        bytes.map { |byte| byte.is_a?(Integer) ? "#{byte}u" : "((unsigned char)(#{byte}))" }.join(", ")
      end

      def global_string_memory_initializer
        bytes = global_string_bytes.empty? ? [0] : global_string_bytes
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
          "    enum { PF_LLVM_STRING_MEMORY_SIZE = #{[global_string_bytes.length, 1].max} };",
          "    const unsigned long long PF_LLVM_GLOBAL_POINTER_TAG = 9223372036854775808ull;",
          "    const unsigned long long PF_LLVM_READONLY_POINTER_TAG = 4611686018427387904ull;",
          "    const unsigned long long PF_LLVM_STRING_POINTER_TAG = 2305843009213693952ull;",
          "    const unsigned long long PF_LLVM_POINTER_OFFSET_MASK = 2305843009213693951ull;",
          "    unsigned char llvm_memory[PF_LLVM_MEMORY_SIZE] = {0};",
          "    unsigned char llvm_global_memory[PF_LLVM_GLOBAL_MEMORY_SIZE] = {#{global_memory_initializer}};",
          "    const unsigned char llvm_string_memory[PF_LLVM_STRING_MEMORY_SIZE] = {#{global_string_memory_initializer}};",
          "    int pf_return_code = 0;",
          "    int pf_slot_index = 0;",
          "    int pf_ch = 0;"
        ]
        registers.each_value do |name|
          lines << "    unsigned long long #{name} = 0;"
        end
        i128_high_registers.each_value do |name|
          lines << "    unsigned long long #{name} = 0;"
        end
        aggregate_registers.each_value do |aggregate|
          lines << "    unsigned char #{aggregate.fetch(:name)}[#{aggregate.fetch(:size)}] = {0};"
        end
        lines << "    (void)llvm_memory;"
        lines << "    (void)llvm_global_memory;"
        lines << "    (void)llvm_string_memory;"
        lines << "    (void)pf_slot_index;"
        lines << "    (void)pf_ch;"
        registers.each_value do |name|
          lines << "    (void)#{name};"
        end
        i128_high_registers.each_value do |name|
          lines << "    (void)#{name};"
        end
        aggregate_registers.each_value do |aggregate|
          lines << "    (void)#{aggregate.fetch(:name)};"
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
        lines.reject { |line| phi?(line) || debug_record?(line) }
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
          when :freeze then return emit_freeze(line)
          when :extractelement then return emit_extractelement(line)
          when :insertelement then return emit_insertelement(line)
          when :extractvalue then return emit_extractvalue(line)
          when :insertvalue then return emit_insertvalue(line)
          when :icmp then return emit_icmp(line)
          when :call then return emit_call(line)
          when :switch then return emit_switch(label, line)
          when :branch then return emit_branch(label, line)
          when :return then return emit_return(line)
          when :unreachable then return emit_unreachable
          end

          raise Frontend::LLVMSubset::ParseError, unsupported_instruction_message(line)
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

        if line.respond_to?(:destination) && line.respond_to?(:base_pointer) && line.respond_to?(:source_type)
          base_address = memory_address(line.base_pointer)
          offset = gep_offset_expression(line.source_type, line.indices, base_address.offset)
          pointers[line.destination] = pointer_from_address(base_address, offset)
          return []
        end

        if (match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+(?:inbounds|nuw|nusw|inrange))*\s+\[(\d+)\s+x\s+i8\],\s+(?:ptr|.+?\*)\s+(#{GLOBAL_NAME}),\s+i\d+\s+(-?\d+),\s+i\d+\s+(-?\d+)\z/)) && global_strings.key?(match[3])
          pointers[match[1]] = GlobalStringPointer.new(
            name: match[3],
            offset: (match[4].to_i * match[2].to_i) + match[5].to_i
          )
          return []
        end

        if (match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+(?:inbounds|nuw|nusw|inrange))*\s+\[(\d+)\s+x\s+i(1|8|16|32|64)\],\s+(?:ptr|.+?\*)\s+(#{POINTER_NAME}),\s+i\d+\s+(.+?),\s+i\d+\s+(.+)\z/))
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

        match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+(?:inbounds|nuw|nusw|inrange))*\s+i(1|8|16|32|64),\s+(?:ptr|.+?\*)\s+(#{POINTER_NAME}),\s+i\d+\s+(.+)\z/)
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
        elsif line.respond_to?(:value_type) && line.value_type == "ptr"
          return emit_pointer_store(line.value, line.pointer)
        elsif line.respond_to?(:value_type) && line.value_type && aggregate_type?(line.value_type)
          return emit_aggregate_store(line.value_type, line.value, line.pointer)
        else
          if (vector_match = line.match(/\Astore\s+(<\d+\s+x\s+i(?:8|16|32|64)>)\s+(.+?),\s+(?:ptr|.+?\*)\s+(?:.+\s+)?(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/))
            return emit_aggregate_store(vector_match[1], vector_match[2], vector_match[3])
          end
          if (aggregate_match = line.match(/\Astore\s+(.+?)\s+(.+?),\s+(?:ptr|.+?\*)\s+(?:.+\s+)?(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/)) && aggregate_type?(aggregate_match[1])
            return emit_aggregate_store(aggregate_match[1], aggregate_match[2], aggregate_match[3])
          end
          if (pointer_match = line.match(/\Astore\s+(?:ptr|.+?\*)\s+(.+?),\s+(?:ptr|.+?\*)\s+(?:.+\s+)?(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/))
            return emit_pointer_store(pointer_match[1], pointer_match[2])
          end

          match = line.match(/\Astore\s+i(1|8|16|32|64)\s+(.+?),\s+(?:ptr|.+?\*)\s+(?:.+\s+)?(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported store: #{line}" unless match

          bits = match[1].to_i
          value = match[2]
          pointer = match[3]
        end
        return emit_i128_store(value, pointer) if bits == 128

        width = byte_width(bits)
        address = memory_address(pointer)
        ensure_writable_address!(address)
        dynamic_writable_address_lines(address) + slot_lines(address, width) + [
          "    pf_llvm_store(#{address.memory}, pf_slot_index, (unsigned long long)(#{llvm_value(value)} & #{integer_mask_literal(bits)}), #{width});"
        ]
      end

      def emit_load(line)
        if line.respond_to?(:destination) && line.respond_to?(:bits) && line.respond_to?(:pointer) && line.bits
          destination = line.destination
          bits = line.bits
          pointer = line.pointer
        elsif line.respond_to?(:value_type) && line.value_type == "ptr"
          return emit_pointer_load(line.destination, line.pointer)
        elsif line.respond_to?(:value_type) && line.value_type && aggregate_type?(line.value_type)
          return emit_aggregate_load(line.destination, line.value_type, line.pointer)
        else
          if (aggregate_match = line.match(/\A(#{NAME})\s*=\s*load\s+(.+?),\s+(?:ptr|.+?\*)\s+(?:.+\s+)?(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/)) && aggregate_type?(aggregate_match[2])
            return emit_aggregate_load(aggregate_match[1], aggregate_match[2], aggregate_match[3])
          end
          if (pointer_match = line.match(/\A(#{NAME})\s*=\s*load\s+(?:ptr|.+?\*),\s+(?:ptr|.+?\*)\s+(?:.+\s+)?(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/))
            return emit_pointer_load(pointer_match[1], pointer_match[2])
          end

          match = line.match(/\A(#{NAME})\s*=\s*load\s+i(1|8|16|32|64),\s+(?:ptr|.+?\*)\s+(?:.+\s+)?(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported load: #{line}" unless match

          destination = match[1]
          bits = match[2].to_i
          pointer = match[3]
        end
        return emit_i128_load(destination, pointer) if bits == 128

        width = byte_width(bits)
        address = memory_address(pointer)
        slot_lines(address, width) + [
          "    #{register(destination)} = #{unsigned_cast(bits)}(pf_llvm_load(#{address.memory}, pf_slot_index, #{width}) & #{integer_mask_literal(bits)});"
        ]
      end

      def emit_binary(line)
        return emit_vector_binary(line) if line.respond_to?(:vector_type) && line.vector_type

        if line.respond_to?(:destination) && line.respond_to?(:operator) && line.respond_to?(:bits) && line.bits
          destination = line.destination
          operator = line.operator
          bits = line.bits
          left = line.left
          right = line.right
        else
          match = line.match(/\A(#{NAME})\s*=\s*(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)(?:\s+(?:nuw|nsw|exact))*\s+i(1|8|16|32|64)\s+(.+?),\s+(.+)\z/)
          raise Frontend::LLVMSubset::ParseError, unsupported_instruction_message(line) unless match

          destination = match[1]
          operator = match[2]
          bits = match[3].to_i
          left = match[4]
          right = match[5]
        end
        return emit_i128_binary(destination, operator, left, right) if bits == 128

        expression = binary_expression(operator, bits, llvm_value(left), llvm_value(right))
        ["    #{register(destination)} = #{unsigned_cast(bits)}((#{expression}) & #{integer_mask_literal(bits)});"]
      end

      def emit_select(line)
        return emit_vector_select(line) if line.respond_to?(:vector_type) && line.vector_type

        if line.respond_to?(:value_type) && line.value_type == "ptr"
          condition = llvm_value(line.condition)
          true_value = encoded_pointer_value(line.true_value)
          false_value = encoded_pointer_value(line.false_value)
          pointers[line.destination] = EncodedPointer.new(value: "(((#{condition}) != 0u) ? (#{true_value}) : (#{false_value}))")
          return []
        end

        if line.respond_to?(:destination) && line.respond_to?(:condition) && line.respond_to?(:bits) && line.bits
          return emit_i128_select(line.destination, line.condition, line.true_value, line.false_value) if line.bits == 128

          condition = llvm_value(line.condition)
          true_value = llvm_value(line.true_value)
          false_value = llvm_value(line.false_value)
          return ["    #{register(line.destination)} = #{unsigned_cast(line.bits)}(((#{condition}) != 0u ? (#{true_value}) : (#{false_value})) & #{integer_mask_literal(line.bits)});"]
        end

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
          return emit_pointer_bitcast(line.destination, line.value) if line.operator == "bitcast"
          return emit_addrspacecast(line.destination, line.value, line.from_type, line.to_type) if line.operator == "addrspacecast"

          if line.from_bits
            destination = line.destination
            operator = line.operator
            from_bits = line.from_bits
            value = line.value
            to_bits = line.to_bits
          end
        elsif (match = line.match(/\A(#{NAME})\s*=\s*ptrtoint\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\s+(.+?)\s+to\s+i(1|8|16|32|64)\z/))
          return emit_ptrtoint_cast(match[1], match[2], match[3].to_i)
        elsif (match = line.match(/\A(#{NAME})\s*=\s*inttoptr\s+i(?:1|8|16|32|64)\s+(.+?)\s+to\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\z/))
          return emit_inttoptr_cast(match[1], match[2])
        elsif (match = line.match(/\A(#{NAME})\s*=\s*bitcast\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\s+(.+?)\s+to\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\z/))
          return emit_pointer_bitcast(match[1], match[2])
        elsif (match = line.match(/\A(#{NAME})\s*=\s*addrspacecast\s+(.+?)\s+(.+?)\s+to\s+(.+)\z/))
          return emit_addrspacecast(match[1], match[3], match[2], match[4])
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
        return emit_i128_extend(destination, operator, from_bits, value) if to_bits == 128
        raise Frontend::LLVMSubset::ParseError, "unsupported i128 cast: #{line}" if from_bits == 128 && operator != "trunc"

        ["    #{register(destination)} = #{cast_expression(operator, from_bits, to_bits, llvm_value(value))};"]
      end

      def emit_ptrtoint_cast(destination, value, to_bits, context: nil)
        encoded = encoded_pointer_value(value, context:)
        target = context ? inline_register(context, destination) : register(destination)
        ["    #{target} = #{unsigned_cast(to_bits)}((#{encoded}) & #{integer_mask_literal(to_bits)});"]
      end

      def emit_freeze(line)
        if line.value_type == "ptr"
          pointers[line.destination] = EncodedPointer.new(value: register(line.destination))
          return ["    #{register(line.destination)} = #{encoded_pointer_value(line.value)};"]
        end
        unless line.bits
          raise Frontend::LLVMSubset::ParseError, "unsupported freeze type: #{line.value_type}"
        end

        ["    #{register(line.destination)} = #{unsigned_cast(line.bits)}((#{llvm_value(line.value)}) & #{integer_mask_literal(line.bits)});"]
      end

      def emit_extractvalue(line)
        aggregate_type = line.aggregate_type
        offset, value_type = aggregate_index_info(aggregate_type, line.indices)
        if pointer_type_name?(value_type)
          aggregate = aggregate_register(line.aggregate)
          pointers[line.destination] = EncodedPointer.new(value: register(line.destination))
          return ["    #{register(line.destination)} = pf_llvm_load(#{aggregate.fetch(:name)}, #{offset}, #{pointer_size});"]
        end
        unless value_type.match?(/\Ai(?:1|8|16|32|64)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported extractvalue result type: #{value_type}"
        end

        bits = value_type.delete_prefix("i").to_i
        aggregate = aggregate_register(line.aggregate)
        [
          "    #{register(line.destination)} = #{unsigned_cast(bits)}(pf_llvm_load(#{aggregate.fetch(:name)}, #{offset}, #{byte_width(bits)}) & #{integer_mask_literal(bits)});"
        ]
      end

      def emit_extractelement(line, context: nil)
        source = aggregate_value_bytes(line.vector, line.vector_type, context:)
        index = context ? inline_value(line.index, context) : llvm_value(line.index)
        width = byte_width(line.bits)
        destination = context ? inline_register(context, line.destination) : register(line.destination)
        return ["    #{destination} = 0u;"] if source.nil?

        prefix = next_aggregate_copy_prefix
        [
          "    {",
          "        long long #{prefix}_index = (long long)(#{index});",
          "        if (#{prefix}_index < 0 || #{prefix}_index >= #{vector_element_count(line.vector_type)}) {",
          "            fprintf(stderr, \"pfc runtime error: LLVM vector index out of range\\n\");",
          "            PF_ABORT();",
          "        }",
          "        #{destination} = #{unsigned_cast(line.bits)}(pf_llvm_load(#{source}, #{prefix}_index * #{width}, #{width}) & #{integer_mask_literal(line.bits)});",
          "    }"
        ]
      end

      def emit_insertelement(line, context: nil)
        aggregate = aggregate_register(line.destination, context:)
        source = aggregate_value_bytes(line.vector, line.vector_type, context:)
        index = context ? inline_value(line.index, context) : llvm_value(line.index)
        value = context ? inline_value(line.value, context) : llvm_value(line.value)
        width = byte_width(line.bits)
        copy_prefix = next_aggregate_copy_prefix
        [
          "    {",
          "        int #{copy_prefix}_i = 0;",
          "        long long #{copy_prefix}_index = (long long)(#{index});",
          "        if (#{copy_prefix}_index < 0 || #{copy_prefix}_index >= #{vector_element_count(line.vector_type)}) {",
          "            fprintf(stderr, \"pfc runtime error: LLVM vector index out of range\\n\");",
          "            PF_ABORT();",
          "        }",
          "        for (#{copy_prefix}_i = 0; #{copy_prefix}_i < #{aggregate.fetch(:size)}; #{copy_prefix}_i++) {",
          "            #{aggregate.fetch(:name)}[#{copy_prefix}_i] = #{source ? "#{source}[#{copy_prefix}_i]" : '0u'};",
          "        }",
          "        pf_llvm_store(#{aggregate.fetch(:name)}, #{copy_prefix}_index * #{width}, (unsigned long long)(#{value} & #{integer_mask_literal(line.bits)}), #{width});",
          "    }"
        ]
      end

      def emit_insertvalue(line)
        aggregate = aggregate_register(line.destination)
        source = aggregate_value_bytes(line.aggregate, line.aggregate_type)
        offset, value_type = aggregate_index_info(line.aggregate_type, line.indices)
        if pointer_type_name?(value_type)
          copy_prefix = next_aggregate_copy_prefix
          encoded = encoded_pointer_value(line.value)
          return [
            "    {",
            "        int #{copy_prefix}_i = 0;",
            "        for (#{copy_prefix}_i = 0; #{copy_prefix}_i < #{aggregate.fetch(:size)}; #{copy_prefix}_i++) {",
            "            #{aggregate.fetch(:name)}[#{copy_prefix}_i] = #{source ? "#{source}[#{copy_prefix}_i]" : '0u'};",
            "        }",
            "        pf_llvm_store(#{aggregate.fetch(:name)}, #{offset}, #{encoded}, #{pointer_size});",
            "    }"
          ]
        end
        unless value_type.match?(/\Ai(?:1|8|16|32|64)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported insertvalue field type: #{value_type}"
        end

        bits = value_type.delete_prefix("i").to_i
        copy_prefix = next_aggregate_copy_prefix
        [
          "    {",
          "        int #{copy_prefix}_i = 0;",
          "        for (#{copy_prefix}_i = 0; #{copy_prefix}_i < #{aggregate.fetch(:size)}; #{copy_prefix}_i++) {",
          "            #{aggregate.fetch(:name)}[#{copy_prefix}_i] = #{source ? "#{source}[#{copy_prefix}_i]" : '0u'};",
          "        }",
          "        pf_llvm_store(#{aggregate.fetch(:name)}, #{offset}, (unsigned long long)(#{llvm_value(line.value)} & #{integer_mask_literal(bits)}), #{byte_width(bits)});",
          "    }"
        ]
      end

      def emit_inttoptr_cast(destination, value, context: nil)
        pointer = context ? inline_value(value, context) : llvm_value(value)
        pointer_map = context ? context.fetch(:pointers) : pointers
        pointer_map[destination] = EncodedPointer.new(value: pointer)
        []
      end

      def emit_pointer_bitcast(destination, value, context: nil)
        pointer_map = context ? context.fetch(:pointers) : pointers
        pointer_map[destination] = pointer_binding(value, context:)
        []
      end

      def emit_addrspacecast(destination, value, from_type, to_type, context: nil)
        unless zero_addrspace_pointer_type?(from_type) && zero_addrspace_pointer_type?(to_type)
          raise Frontend::LLVMSubset::ParseError, "unsupported non-zero address space cast: #{from_type} to #{to_type}"
        end

        emit_pointer_bitcast(destination, value, context:)
      end

      def emit_pointer_load(destination, pointer)
        address = memory_address(pointer)
        pointers[destination] = EncodedPointer.new(value: register(destination))
        slot_lines(address, pointer_size) + [
          "    #{register(destination)} = pf_llvm_load(#{address.memory}, pf_slot_index, #{pointer_size});"
        ]
      end

      def emit_pointer_store(value, pointer)
        address = memory_address(pointer)
        ensure_writable_address!(address)
        dynamic_writable_address_lines(address) + slot_lines(address, pointer_size) + [
          "    pf_llvm_store(#{address.memory}, pf_slot_index, #{encoded_pointer_value(value)}, #{pointer_size});"
        ]
      end

      def emit_i128_load(destination, pointer)
        address = memory_address(pointer)
        slot_lines(address, 16) + [
          "    #{register(destination)} = pf_llvm_load(#{address.memory}, pf_slot_index, 8);",
          "    #{i128_high_register(destination)} = pf_llvm_load(#{address.memory}, pf_slot_index + 8, 8);"
        ]
      end

      def emit_i128_store(value, pointer)
        address = memory_address(pointer)
        ensure_writable_address!(address)
        low = i128_low64_value(value)
        high = i128_high64_value(value)
        dynamic_writable_address_lines(address) + slot_lines(address, 16) + [
          "    pf_llvm_store(#{address.memory}, pf_slot_index, #{low}, 8);",
          "    pf_llvm_store(#{address.memory}, pf_slot_index + 8, #{high}, 8);"
        ]
      end

      def emit_aggregate_load(destination, value_type, pointer)
        aggregate = aggregate_register(destination)
        address = memory_address(pointer)
        prefix = next_aggregate_copy_prefix
        slot_lines(address, aggregate.fetch(:size)) + [
          "    {",
          "        int #{prefix}_i = 0;",
          "        for (#{prefix}_i = 0; #{prefix}_i < #{aggregate.fetch(:size)}; #{prefix}_i++) {",
          "            #{aggregate.fetch(:name)}[#{prefix}_i] = #{address.memory}[pf_slot_index + #{prefix}_i];",
          "        }",
          "    }"
        ]
      end

      def emit_aggregate_store(value_type, value, pointer)
        size = type_size(value_type)
        address = memory_address(pointer)
        ensure_writable_address!(address)
        source = aggregate_value_bytes(value, value_type)
        prefix = next_aggregate_copy_prefix
        dynamic_writable_address_lines(address) + slot_lines(address, size) + [
          "    {",
          "        int #{prefix}_i = 0;",
          "        for (#{prefix}_i = 0; #{prefix}_i < #{size}; #{prefix}_i++) {",
          "            #{address.memory}[pf_slot_index + #{prefix}_i] = #{source ? "#{source}[#{prefix}_i]" : '0u'};",
          "        }",
          "    }"
        ]
      end

      def emit_icmp(line)
        return emit_vector_icmp(line) if line.respond_to?(:vector_type) && line.vector_type

        if line.respond_to?(:operand_type) && line.operand_type == "ptr"
          return emit_pointer_icmp(line.destination, line.predicate, line.left, line.right)
        end

        if line.respond_to?(:destination) && line.respond_to?(:predicate) && line.respond_to?(:bits) && line.bits
          destination = line.destination
          predicate = line.predicate
          bits = line.bits
          left = bits == 128 ? line.left : llvm_value(line.left)
          right = bits == 128 ? line.right : llvm_value(line.right)
        elsif (match = line.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne)\s+ptr\s+(.+?),\s+(.+)\z/))
          return emit_pointer_icmp(match[1], match[2], match[3], match[4])
        else
          match = line.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne|ugt|uge|ult|ule|sgt|sge|slt|sle)\s+i(1|8|16|32|64)\s+(.+?),\s+(.+)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported icmp: #{line}" unless match

          destination = match[1]
          predicate = match[2]
          bits = match[3].to_i
          left = llvm_value(match[4])
          right = llvm_value(match[5])
        end
        return emit_i128_icmp(destination, predicate, left, right) if bits == 128

        operator = icmp_operator(predicate)
        if predicate.start_with?("s")
          left = signed_expression(left, bits)
          right = signed_expression(right, bits)
        end
        ["    #{register(destination)} = ((#{left}) #{operator} (#{right})) ? 1u : 0u;"]
      end

      def emit_pointer_icmp(destination, predicate, left, right, context: nil)
        unless %w[eq ne].include?(predicate)
          raise Frontend::LLVMSubset::ParseError, "unsupported pointer icmp predicate: #{predicate}"
        end

        target = context ? inline_register(context, destination) : register(destination)
        operator = predicate == "eq" ? "==" : "!="
        left_value = encoded_pointer_value(left, context:)
        right_value = encoded_pointer_value(right, context:)
        ["    #{target} = ((#{left_value}) #{operator} (#{right_value})) ? 1u : 0u;"]
      end

      def emit_call(line)
        call = parsed_call(line)
        validate_call_signature!(call, line)
        return [] if llvm_noop_intrinsic?(call.fetch(:function_name))
        return emit_expect_intrinsic(call) if llvm_expect_intrinsic?(call.fetch(:function_name))
        return emit_memory_intrinsic_call(call) if llvm_memory_intrinsic?(call.fetch(:function_name))
        return emit_numeric_intrinsic_call(call) if llvm_numeric_intrinsic?(call.fetch(:function_name))

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

        value = llvm_value(match[2])
        output = ["    if (pf_output_cell((unsigned char)(#{value})) != 0) PF_ABORT();"]
        output << "    #{register(match[1])} = (unsigned int)(unsigned char)(#{value});" if match[1]
        output
      end

      def emit_internal_call(line)
        match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+(i(?:1|8|16|32|64|128)|<\d+\s+x\s+i(?:1|8|16|32|64)>|ptr|void)\s+@([-A-Za-z$._0-9]+)\((.*)\)\z/)
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
                               caller_context ? inline_value_storage(caller_context, destination, function.fetch(:return_type)) : value_storage(destination, function.fetch(:return_type))
                             else
                               "#{prefix}_ignored_return"
                             end
        context = inline_context(prefix, return_destination, function, call_stack + [function.fetch(:name)])
        if destination && function.fetch(:return_type) == "ptr"
          pointer_map = caller_context ? caller_context.fetch(:pointers) : pointers
          pointer_map[destination] = EncodedPointer.new(value: return_destination)
        end
        if function.fetch(:return_type) == "i128"
          context[:return_high_destination] = if destination
                                                caller_context ? i128_high_register(destination, context: caller_context) : i128_high_register(destination)
                                              else
                                                "#{prefix}_ignored_return_hi"
                                              end
        end
        if destination && aggregate_type?(function.fetch(:return_type))
          context[:return_aggregate_destination] = caller_context ? aggregate_register(destination, context: caller_context) : aggregate_register(destination)
        elsif aggregate_type?(function.fetch(:return_type))
          context[:return_aggregate_destination] = { name: "#{prefix}_ignored_return_agg", size: type_size(function.fetch(:return_type)), type: function.fetch(:return_type) }
        end
        lines = inline_declarations(context, function)
        function.fetch(:params).zip(arguments).each_with_index do |(param, argument), index|
          param_type = function.fetch(:param_types).fetch(index)
          if param_type == "ptr"
            context.fetch(:pointers)[param] = pointer_binding(argument, context: caller_context)
            next
          end
          if param_type == "i128"
            local = context.fetch(:values).fetch(param)
            high = context.fetch(:i128_high_values).fetch(param)
            lines << "    #{local} = #{i128_low64_value(argument, context: caller_context)};"
            lines << "    #{high} = #{i128_high64_value(argument, context: caller_context)};"
            next
          end
          if aggregate_type?(param_type)
            aggregate = context.fetch(:aggregates).fetch(param)
            source = aggregate_value_bytes(argument, param_type, context: caller_context)
            prefix_copy = next_aggregate_copy_prefix
            lines.concat([
              "    {",
              "        int #{prefix_copy}_i = 0;",
              "        for (#{prefix_copy}_i = 0; #{prefix_copy}_i < #{aggregate.fetch(:size)}; #{prefix_copy}_i++) {",
              "            #{aggregate.fetch(:name)}[#{prefix_copy}_i] = #{source ? "#{source}[#{prefix_copy}_i]" : '0u'};",
              "        }",
              "    }"
            ])
            next
          end

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
        i128_high_values = {}
        aggregates = {}
        pointers = function.fetch(:allocations).dup
        function.fetch(:params).each_with_index do |param, index|
          param_type = function.fetch(:param_types).fetch(index)
          next if param_type == "ptr"

          values[param] = "#{prefix}_arg#{index}"
          i128_high_values[param] = "#{prefix}_arg#{index}_hi" if param_type == "i128"
          aggregates[param] = { name: "#{prefix}_arg#{index}_agg", size: type_size(param_type), type: param_type } if aggregate_type?(param_type)
        end
        inline_register_names(function).each do |name|
          values[name] ||= "#{prefix}_#{name.delete_prefix('%').gsub(/[^A-Za-z0-9_]/, '_')}"
        end
        function.fetch(:blocks).values.flatten.each do |line|
          lhs = line[/\A(#{NAME})\s*=/, 1]
          lhs = line.destination if lhs.nil? && line.respond_to?(:destination)
          next unless lhs
          if (line.respond_to?(:bits) && line.bits == 128) || (line.respond_to?(:to_bits) && line.to_bits == 128) || (line.respond_to?(:return_type) && line.return_type == "i128")
            i128_high_values[lhs] ||= "#{values.fetch(lhs)}_hi"
          end
          type = if line.respond_to?(:return_type) && aggregate_type?(line.return_type)
                   line.return_type
                 elsif line.respond_to?(:value_type) && aggregate_type?(line.value_type)
                   line.value_type
                 elsif line.respond_to?(:vector_type) && aggregate_type?(line.vector_type) &&
                       (line.respond_to?(:value) || line.respond_to?(:operator) || line.respond_to?(:predicate) || line.respond_to?(:true_value))
                   line.vector_type
                 end
          aggregates[lhs] ||= { name: "#{prefix}_#{c_aggregate_name(lhs)}", size: type_size(type), type: } if type
        end
        function.fetch(:blocks).values.flatten.each do |line|
          lhs = line[/\A(#{NAME})\s*=\s*phi\s+(?:ptr|.+?\*)\b/, 1]
          pointers[lhs] = EncodedPointer.new(value: values.fetch(lhs)) if lhs
        end
        {
          call_stack:,
          declare_return_destination: function.fetch(:return_type) != "void" &&
            return_destination.start_with?("#{prefix}_ignored_return"),
          aggregates:,
          function:,
          i128_high_values:,
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
          next nil if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*bitcast\s+(?:ptr|.+?\*)\b/)
          next nil if line.match?(/\A#{Regexp.escape(lhs)}\s*=\s*select\s+i1\s+.+?,\s+ptr\b/)

          lhs
        end.uniq
      end

      def inline_declarations(context, function)
        declared = []
        lines = []
        function.fetch(:params).each_with_index do |param, index|
          param_type = function.fetch(:param_types).fetch(index)
          next if param_type == "ptr"

          name = context.fetch(:values).fetch(param)
          lines << "    unsigned long long #{name} = 0;"
          declared << name
          if param_type == "i128"
            high = context.fetch(:i128_high_values).fetch(param)
            lines << "    unsigned long long #{high} = 0;"
            declared << high
          end
          if aggregate_type?(param_type)
            aggregate = context.fetch(:aggregates).fetch(param)
            lines << "    unsigned char #{aggregate.fetch(:name)}[#{aggregate.fetch(:size)}] = {0};"
            declared << aggregate.fetch(:name)
          end
        end
        inline_register_names(function).each do |register_name|
          name = context.fetch(:values).fetch(register_name)
          next if declared.include?(name)

          lines << "    unsigned long long #{name} = 0;"
          declared << name
          if context.fetch(:i128_high_values).key?(register_name)
            high = context.fetch(:i128_high_values).fetch(register_name)
            lines << "    unsigned long long #{high} = 0;" unless declared.include?(high)
            declared << high
          end
          if context.fetch(:aggregates).key?(register_name)
            aggregate = context.fetch(:aggregates).fetch(register_name)
            lines << "    unsigned char #{aggregate.fetch(:name)}[#{aggregate.fetch(:size)}] = {0};" unless declared.include?(aggregate.fetch(:name))
            declared << aggregate.fetch(:name)
          end
        end
        lines << "    unsigned long long #{context.fetch(:return_destination)} = 0;" if context.fetch(:declare_return_destination)
        if context.fetch(:declare_return_destination) && context.key?(:return_high_destination)
          lines << "    unsigned long long #{context.fetch(:return_high_destination)} = 0;"
        end
        if context.key?(:return_aggregate_destination) && context.fetch(:return_aggregate_destination).fetch(:name).start_with?("#{context.fetch(:prefix)}_ignored_return_agg")
          aggregate = context.fetch(:return_aggregate_destination)
          lines << "    unsigned char #{aggregate.fetch(:name)}[#{aggregate.fetch(:size)}] = {0};"
        end
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
          when :freeze then return emit_inline_freeze(line, context)
          when :extractelement then return emit_extractelement(line, context:)
          when :insertelement then return emit_insertelement(line, context:)
          when :icmp then return emit_inline_icmp(line, context)
          when :call then return emit_inline_call(line, context)
          when :switch then return emit_inline_switch(line, context, label)
          when :branch then return emit_inline_branch(line, context, label)
          when :return then return emit_inline_return(line, context)
          when :unreachable then return emit_unreachable
          end

          raise Frontend::LLVMSubset::ParseError, unsupported_instruction_message(line)
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

        if line.respond_to?(:destination) && line.respond_to?(:base_pointer) && line.respond_to?(:source_type)
          base_address = memory_address(line.base_pointer, context:)
          offset = gep_offset_expression(line.source_type, line.indices, base_address.offset, context:)
          context.fetch(:pointers)[line.destination] = pointer_from_address(base_address, offset)
          return []
        end

        if (match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+(?:inbounds|nuw|nusw|inrange))*\s+\[(\d+)\s+x\s+i8\],\s+(?:ptr|.+?\*)\s+(#{GLOBAL_NAME}),\s+i\d+\s+(-?\d+),\s+i\d+\s+(-?\d+)\z/)) && global_strings.key?(match[3])
          context.fetch(:pointers)[match[1]] = GlobalStringPointer.new(
            name: match[3],
            offset: (match[4].to_i * match[2].to_i) + match[5].to_i
          )
          return []
        end

        if (match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+(?:inbounds|nuw|nusw|inrange))*\s+\[(\d+)\s+x\s+i(1|8|16|32|64)\],\s+(?:ptr|.+?\*)\s+(#{POINTER_NAME}),\s+i\d+\s+(.+?),\s+i\d+\s+(.+)\z/))
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

        match = line.match(/\A(#{NAME})\s*=\s*getelementptr(?:\s+(?:inbounds|nuw|nusw|inrange))*\s+i(1|8|16|32|64),\s+(?:ptr|.+?\*)\s+(#{POINTER_NAME}),\s+i\d+\s+(.+)\z/)
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
        elsif line.respond_to?(:value_type) && line.value_type == "ptr"
          return emit_inline_pointer_store(line.value, line.pointer, context)
        else
          if (pointer_match = line.match(/\Astore\s+(?:ptr|.+?\*)\s+(.+?),\s+(?:ptr|.+?\*)\s+(?:.+\s+)?(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/))
            return emit_inline_pointer_store(pointer_match[1], pointer_match[2], context)
          end

          match = line.match(/\Astore\s+i(1|8|16|32|64)\s+(.+?),\s+(?:ptr|.+?\*)\s+(?:.+\s+)?(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported store: #{line}" unless match

          bits = match[1].to_i
          value = match[2]
          pointer = match[3]
        end
        width = byte_width(bits)
        address = memory_address(pointer, context:)
        ensure_writable_address!(address)
        dynamic_writable_address_lines(address) + inline_slot_lines(address, width) + [
          "    pf_llvm_store(#{address.memory}, pf_slot_index, (unsigned long long)(#{inline_value(value, context)} & #{integer_mask_literal(bits)}), #{width});"
        ]
      end

      def emit_inline_load(line, context)
        if line.respond_to?(:destination) && line.respond_to?(:bits) && line.respond_to?(:pointer) && line.bits
          destination = line.destination
          bits = line.bits
          pointer = line.pointer
        elsif line.respond_to?(:value_type) && line.value_type == "ptr"
          return emit_inline_pointer_load(line.destination, line.pointer, context)
        else
          if (pointer_match = line.match(/\A(#{NAME})\s*=\s*load\s+(?:ptr|.+?\*),\s+(?:ptr|.+?\*)\s+(?:.+\s+)?(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/))
            return emit_inline_pointer_load(pointer_match[1], pointer_match[2], context)
          end

          match = line.match(/\A(#{NAME})\s*=\s*load\s+i(1|8|16|32|64),\s+(?:ptr|.+?\*)\s+(?:.+\s+)?(#{POINTER_NAME})(?:,\s+align\s+\d+)?\z/)
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
        return emit_vector_binary(line, context:) if line.respond_to?(:vector_type) && line.vector_type

        if line.respond_to?(:destination) && line.respond_to?(:operator) && line.respond_to?(:bits) && line.bits
          destination = line.destination
          operator = line.operator
          bits = line.bits
          left = line.left
          right = line.right
        else
          match = line.match(/\A(#{NAME})\s*=\s*(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)(?:\s+(?:nuw|nsw|exact))*\s+i(1|8|16|32|64)\s+(.+?),\s+(.+)\z/)
          raise Frontend::LLVMSubset::ParseError, unsupported_instruction_message(line) unless match

          destination = match[1]
          operator = match[2]
          bits = match[3].to_i
          left = match[4]
          right = match[5]
        end
        return emit_i128_binary(destination, operator, left, right, context:) if bits == 128

        local = inline_register(context, destination)
        expression = binary_expression(operator, bits, inline_value(left, context), inline_value(right, context))
        ["    #{local} = #{unsigned_cast(bits)}((#{expression}) & #{integer_mask_literal(bits)});"]
      end

      def emit_inline_select(line, context)
        return emit_vector_select(line, context:) if line.respond_to?(:vector_type) && line.vector_type

        if line.respond_to?(:value_type) && line.value_type == "ptr"
          condition = inline_value(line.condition, context)
          true_value = encoded_pointer_value(line.true_value, context:)
          false_value = encoded_pointer_value(line.false_value, context:)
          context.fetch(:pointers)[line.destination] = EncodedPointer.new(value: "(((#{condition}) != 0u) ? (#{true_value}) : (#{false_value}))")
          return []
        end

        if line.respond_to?(:destination) && line.respond_to?(:condition) && line.respond_to?(:bits) && line.bits
          return emit_i128_select(line.destination, line.condition, line.true_value, line.false_value, context:) if line.bits == 128

          local = inline_register(context, line.destination)
          condition = inline_value(line.condition, context)
          true_value = inline_value(line.true_value, context)
          false_value = inline_value(line.false_value, context)
          return ["    #{local} = #{unsigned_cast(line.bits)}(((#{condition}) != 0u ? (#{true_value}) : (#{false_value})) & #{integer_mask_literal(line.bits)});"]
        end

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
          return emit_pointer_bitcast(line.destination, line.value, context:) if line.operator == "bitcast"
          return emit_addrspacecast(line.destination, line.value, line.from_type, line.to_type, context:) if line.operator == "addrspacecast"

          if line.from_bits
            destination = line.destination
            operator = line.operator
            from_bits = line.from_bits
            value = line.value
            to_bits = line.to_bits
          end
        elsif (match = line.match(/\A(#{NAME})\s*=\s*ptrtoint\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\s+(.+?)\s+to\s+i(1|8|16|32|64)\z/))
          return emit_ptrtoint_cast(match[1], match[2], match[3].to_i, context:)
        elsif (match = line.match(/\A(#{NAME})\s*=\s*inttoptr\s+i(?:1|8|16|32|64)\s+(.+?)\s+to\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\z/))
          return emit_inttoptr_cast(match[1], match[2], context:)
        elsif (match = line.match(/\A(#{NAME})\s*=\s*bitcast\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\s+(.+?)\s+to\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\z/))
          return emit_pointer_bitcast(match[1], match[2], context:)
        elsif (match = line.match(/\A(#{NAME})\s*=\s*addrspacecast\s+(.+?)\s+(.+?)\s+to\s+(.+)\z/))
          return emit_addrspacecast(match[1], match[3], match[2], match[4], context:)
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
        return emit_i128_extend(destination, operator, from_bits, value, context:) if to_bits == 128

        local = inline_register(context, destination)
        ["    #{local} = #{cast_expression(operator, from_bits, to_bits, inline_value(value, context))};"]
      end

      def emit_inline_freeze(line, context)
        if line.value_type == "ptr"
          context.fetch(:pointers)[line.destination] = EncodedPointer.new(value: inline_register(context, line.destination))
          return ["    #{inline_register(context, line.destination)} = #{encoded_pointer_value(line.value, context:)};"]
        end
        unless line.bits
          raise Frontend::LLVMSubset::ParseError, "unsupported freeze type: #{line.value_type}"
        end

        ["    #{inline_register(context, line.destination)} = #{unsigned_cast(line.bits)}((#{inline_value(line.value, context)}) & #{integer_mask_literal(line.bits)});"]
      end

      def emit_inline_pointer_load(destination, pointer, context)
        address = memory_address(pointer, context:)
        context.fetch(:pointers)[destination] = EncodedPointer.new(value: inline_register(context, destination))
        inline_slot_lines(address, pointer_size) + [
          "    #{inline_register(context, destination)} = pf_llvm_load(#{address.memory}, pf_slot_index, #{pointer_size});"
        ]
      end

      def emit_inline_pointer_store(value, pointer, context)
        address = memory_address(pointer, context:)
        ensure_writable_address!(address)
        dynamic_writable_address_lines(address) + inline_slot_lines(address, pointer_size) + [
          "    pf_llvm_store(#{address.memory}, pf_slot_index, #{encoded_pointer_value(value, context:)}, #{pointer_size});"
        ]
      end

      def emit_inline_icmp(line, context)
        return emit_vector_icmp(line, context:) if line.respond_to?(:vector_type) && line.vector_type

        if line.respond_to?(:operand_type) && line.operand_type == "ptr"
          return emit_pointer_icmp(line.destination, line.predicate, line.left, line.right, context:)
        end

        if line.respond_to?(:destination) && line.respond_to?(:predicate) && line.respond_to?(:bits) && line.bits
          destination = line.destination
          predicate = line.predicate
          bits = line.bits
          left = bits == 128 ? line.left : inline_value(line.left, context)
          right = bits == 128 ? line.right : inline_value(line.right, context)
        elsif (match = line.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne)\s+ptr\s+(.+?),\s+(.+)\z/))
          return emit_pointer_icmp(match[1], match[2], match[3], match[4], context:)
        else
          match = line.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne|ugt|uge|ult|ule|sgt|sge|slt|sle)\s+i(1|8|16|32|64)\s+(.+?),\s+(.+)\z/)
          raise Frontend::LLVMSubset::ParseError, "unsupported icmp: #{line}" unless match

          destination = match[1]
          predicate = match[2]
          bits = match[3].to_i
          left = inline_value(match[4], context)
          right = inline_value(match[5], context)
        end
        return emit_i128_icmp(destination, predicate, left, right, context:) if bits == 128

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
        return [] if llvm_noop_intrinsic?(call.fetch(:function_name))
        return emit_expect_intrinsic(call, context:) if llvm_expect_intrinsic?(call.fetch(:function_name))
        return emit_memory_intrinsic_call(call, context:) if llvm_memory_intrinsic?(call.fetch(:function_name))
        return emit_numeric_intrinsic_call(call, context:) if llvm_numeric_intrinsic?(call.fetch(:function_name))

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
          match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+(i(?:1|8|16|32|64|128)|<\d+\s+x\s+i(?:1|8|16|32|64)>|ptr|void)\s+@([-A-Za-z$._0-9]+)\((.*)\)\z/)
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

        value = inline_value(match[2], context)
        output = ["    if (pf_output_cell((unsigned char)(#{value})) != 0) PF_ABORT();"]
        output << "    #{inline_register(context, match[1])} = (unsigned int)(unsigned char)(#{value});" if match[1]
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

          if line.return_type == "i128"
            return [
              "    #{context.fetch(:return_destination)} = #{i128_low64_value(line.value, context:)};",
              "    #{context.fetch(:return_high_destination)} = #{i128_high64_value(line.value, context:)};",
              "    goto #{context.fetch(:return_label)};"
            ]
          end
          if aggregate_type?(line.return_type)
            source = aggregate_value_bytes(line.value, line.return_type, context:)
            aggregate = context.fetch(:return_aggregate_destination)
            prefix = next_aggregate_copy_prefix
            return [
              "    {",
              "        int #{prefix}_i = 0;",
              "        for (#{prefix}_i = 0; #{prefix}_i < #{aggregate.fetch(:size)}; #{prefix}_i++) {",
              "            #{aggregate.fetch(:name)}[#{prefix}_i] = #{source ? "#{source}[#{prefix}_i]" : '0u'};",
              "        }",
              "    }",
              "    goto #{context.fetch(:return_label)};"
            ]
          end

          return [
            "    #{context.fetch(:return_destination)} = (unsigned long long)(#{line.return_type == 'ptr' ? encoded_pointer_value(line.value, context:) : inline_value(line.value, context)});",
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
          raise Frontend::LLVMSubset::ParseError, "main cannot return ptr" if line.return_type == "ptr"
          unless line.return_type.match?(/\Ai(?:1|8|16|32|64)\z/)
            raise Frontend::LLVMSubset::ParseError, "main cannot return #{line.return_type}"
          end

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

      def emit_unreachable
        [
          "    fprintf(stderr, \"pfc runtime error: LLVM unreachable executed\\n\");",
          "    PF_ABORT();"
        ]
      end

      def phi_goto(from_label, to_label, indent: 1)
        spaces = "    " * indent
        assignments = phi_lines(to_label).filter_map do |line|
          phi_assignment(line, from_label)
        end.flatten
        lines = simultaneous_phi_assignment_lines(assignments, spaces)
        lines << "#{spaces}goto #{c_label(to_label)};"
        lines
      end

      def phi_lines(label)
        blocks.fetch(label).select { |line| phi?(line) }
      end

      def phi_assignment(line, from_label)
        if line.respond_to?(:value_type) && line.value_type == "ptr"
          value = line.incoming.find { |_value, label| label == from_label }&.first
          return nil if value.nil?

          return {
            expression: encoded_pointer_value(value),
            target: register(line.destination)
          }
        end

        if line.respond_to?(:incoming) && line.incoming && line.bits
          value = line.incoming.find { |_value, label| label == from_label }&.first
          return nil if value.nil?
          if line.bits == 128
            return [
              {
                expression: i128_low64_value(value),
                target: register(line.destination)
              },
              {
                expression: i128_high64_value(value),
                target: i128_high_register(line.destination)
              }
            ]
          end
          if line.respond_to?(:vector_type) && line.vector_type
            return {
              source: aggregate_value_bytes(value, line.vector_type),
              size: type_size(line.vector_type),
              target_aggregate: aggregate_register(line.destination)
            }
          end

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
        end.flatten
        lines = simultaneous_phi_assignment_lines(assignments, spaces)
        lines << "#{spaces}goto #{inline_label(context, to_label)};"
        lines
      end

      def inline_phi_lines(context, label)
        context.fetch(:function).fetch(:blocks).fetch(label).select { |line| phi?(line) }
      end

      def inline_phi_assignment(context, line, from_label)
        if line.respond_to?(:value_type) && line.value_type == "ptr"
          value = line.incoming.find { |_value, label| label == from_label }&.first
          return nil if value.nil?

          return {
            expression: encoded_pointer_value(value, context:),
            target: inline_register(context, line.destination)
          }
        end

        if line.respond_to?(:incoming) && line.incoming && line.bits
          value = line.incoming.find { |_value, label| label == from_label }&.first
          return nil if value.nil?
          if line.bits == 128
            return [
              {
                expression: i128_low64_value(value, context:),
                target: inline_register(context, line.destination)
              },
              {
                expression: i128_high64_value(value, context:),
                target: i128_high_register(line.destination, context:)
              }
            ]
          end
          if line.respond_to?(:vector_type) && line.vector_type
            return {
              source: aggregate_value_bytes(value, line.vector_type, context:),
              size: type_size(line.vector_type),
              target_aggregate: aggregate_register(line.destination, context:)
            }
          end

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
          if assignment.key?(:target_aggregate)
            size = assignment.fetch(:size)
            source = assignment.fetch(:source)
            [
              "#{spaces}unsigned char #{temp_name}[#{size}] = {0};",
              "#{spaces}{",
              "#{spaces}    int #{temp_name}_i = 0;",
              "#{spaces}    for (#{temp_name}_i = 0; #{temp_name}_i < #{size}; #{temp_name}_i++) {",
              "#{spaces}        #{temp_name}[#{temp_name}_i] = #{source ? "#{source}[#{temp_name}_i]" : '0u'};",
              "#{spaces}    }",
              "#{spaces}}"
            ]
          else
            "#{spaces}unsigned long long #{temp_name} = #{assignment.fetch(:expression)};"
          end
        end.flatten
        assignment_lines = assignments.zip(temp_names).map do |assignment, temp_name|
          if assignment.key?(:target_aggregate)
            target = assignment.fetch(:target_aggregate)
            size = assignment.fetch(:size)
            next [
              "#{spaces}{",
              "#{spaces}    int #{temp_name}_i = 0;",
              "#{spaces}    for (#{temp_name}_i = 0; #{temp_name}_i < #{size}; #{temp_name}_i++) {",
              "#{spaces}        #{target.fetch(:name)}[#{temp_name}_i] = #{temp_name}[#{temp_name}_i];",
              "#{spaces}    }",
              "#{spaces}}"
            ]
          end
          "#{spaces}#{assignment.fetch(:target)} = #{temp_name};"
        end.flatten
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
        return "1u" if token == "true"
        return "0u" if token == "false" || token == "undef" || token == "poison" || token == "zeroinitializer"
        return token if token.match?(/\A-?\d+\z/)
        return register(token) if token.match?(/\A#{NAME}\z/)

        raise Frontend::LLVMSubset::ParseError, "unsupported value: #{raw}"
      end

      def inline_value(raw, context)
        token = raw.strip.split(/\s+/).last
        return "1u" if token == "true"
        return "0u" if token == "false" || token == "undef" || token == "poison" || token == "zeroinitializer"
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

      def value_storage(name, value_type)
        return aggregate_register(name).fetch(:name) if aggregate_type?(value_type)

        register(name)
      end

      def inline_value_storage(context, name, value_type)
        return aggregate_register(name, context:).fetch(:name) if aggregate_type?(value_type)

        inline_register(context, name)
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

          format = resolve_printf_format_arguments(parse_printf_format(format_bytes, index), arguments, context:)
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
          when 32
            flags << " "
          when 35
            flags << "#"
          when 43
            flags << "+"
          else
            break
          end
          cursor += 1
        end

        width_argument = false
        if format_bytes[cursor] == 42
          width_argument = true
          width = nil
          cursor += 1
        else
          width, cursor = read_printf_decimal(format_bytes, cursor)
        end
        precision = nil
        precision_argument = false
        if format_bytes[cursor] == 46
          cursor += 1
          if format_bytes[cursor] == 42
            precision_argument = true
            cursor += 1
          else
            precision, cursor = read_printf_decimal(format_bytes, cursor)
            precision ||= 0
          end
        end

        length_modifier = nil
        if format_bytes[cursor] == 104
          if format_bytes[cursor + 1] == 104
            length_modifier = "hh"
            cursor += 2
          else
            length_modifier = "h"
            cursor += 1
          end
        elsif format_bytes[cursor] == 108
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
          precision_argument:,
          precision_expression: nil,
          specifier:,
          width: width || 0,
          width_argument:,
          width_expression: nil,
          zero_pad: flags.include?("0") && !flags.include?("-")
        }
      end

      def resolve_printf_format_arguments(format, arguments, context:)
        resolved = format.dup
        if format.fetch(:width_argument)
          width_argument = arguments.shift
          raise Frontend::LLVMSubset::ParseError, "missing printf dynamic width argument for #{printf_format_label(format)}" if width_argument.nil?

          bits, width_value = typed_integer_value(width_argument, context:)
          signed_width = signed_expression(width_value, bits)
          resolved[:width_expression] = "((#{signed_width}) < 0 ? -(int)(#{signed_width}) : (int)(#{signed_width}))"
          resolved[:left_adjust_expression] = format.fetch(:left_adjust) ? "1" : "((#{signed_width}) < 0 ? 1 : 0)"
        else
          resolved[:width_expression] = format.fetch(:width).to_s
          resolved[:left_adjust_expression] = printf_bool(format.fetch(:left_adjust)).to_s
        end

        if format.fetch(:precision_argument)
          precision_argument = arguments.shift
          raise Frontend::LLVMSubset::ParseError, "missing printf dynamic precision argument for #{printf_format_label(format)}" if precision_argument.nil?

          bits, precision_value = typed_integer_value(precision_argument, context:)
          signed_precision = signed_expression(precision_value, bits)
          resolved[:precision_expression] = "((#{signed_precision}) < 0 ? -1 : (int)(#{signed_precision}))"
          resolved[:precision] = :dynamic
        else
          resolved[:precision_expression] = printf_precision(format).to_s
        end
        resolved
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
          if formatted_integer_format?(format)
            return [
              "    if (pf_output_i64_signed_formatted(#{printf_signed_integer_value(value, output_bits)}, 10u, \"0123456789\", #{printf_width(format)}, #{printf_precision(format)}, #{printf_left_adjust(format)}, #{printf_zero_pad(format)}, #{printf_sign_mode(format)}, &#{count_name}) != 0) PF_ABORT();"
            ]
          end

          helper = output_bits == 64 ? "pf_output_i64_decimal" : "pf_output_i32_decimal"
          cast = signed_cast(output_bits)
          ["    if (#{helper}((#{cast})(#{value}), &#{count_name}) != 0) PF_ABORT();"]
        when "u"
          bits, value = typed_integer_value(argument, context:)
          output_bits = printf_integer_bits(bits, length_modifier)
          if formatted_integer_format?(format)
            return [
              "    if (pf_output_u64_prefixed_formatted(#{printf_unsigned_integer_value(value, output_bits)}, 10u, \"0123456789\", #{printf_width(format)}, #{printf_precision(format)}, #{printf_left_adjust(format)}, #{printf_zero_pad(format)}, 0, &#{count_name}) != 0) PF_ABORT();"
            ]
          end

          helper = output_bits == 64 ? "pf_output_u64_decimal" : "pf_output_u32_decimal"
          cast = unsigned_cast(output_bits).delete_prefix("(").delete_suffix(")")
          ["    if (#{helper}((#{cast})(#{value}), &#{count_name}) != 0) PF_ABORT();"]
        when "x", "X", "o"
          bits, value = typed_integer_value(argument, context:)
          output_bits = printf_integer_bits(bits, length_modifier)
          base = specifier.chr == "o" ? 8 : 16
          digits = specifier.chr == "X" ? "0123456789ABCDEF" : "0123456789abcdef"
          if formatted_integer_format?(format)
            return [
              "    if (pf_output_u64_prefixed_formatted(#{printf_unsigned_integer_value(value, output_bits)}, #{base}u, \"#{digits}\", #{printf_width(format)}, #{printf_precision(format)}, #{printf_left_adjust(format)}, #{printf_zero_pad(format)}, #{printf_prefix_mode(specifier.chr, format)}, &#{count_name}) != 0) PF_ABORT();"
            ]
          end

          helper = output_bits == 64 ? "pf_output_u64_radix" : "pf_output_u32_radix"
          cast = unsigned_cast(output_bits).delete_prefix("(").delete_suffix(")")
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
        when "p"
          if length_modifier || !format.fetch(:precision).nil?
            raise Frontend::LLVMSubset::ParseError, "unsupported printf format: #{printf_format_label(format)}"
          end

          pointer = pointer_argument(argument)
          [
            "    if (pf_output_u64_prefixed_formatted(#{encoded_pointer_value(pointer, context:)}, 16u, \"0123456789abcdef\", #{printf_width(format)}, -1, #{printf_left_adjust(format)}, #{printf_zero_pad(format)}, 4, &#{count_name}) != 0) PF_ABORT();"
          ]
        else
          raise Frontend::LLVMSubset::ParseError, "unsupported printf format: #{printf_format_label(format)}"
        end
      end

      def formatted_integer_format?(format)
        (format.fetch(:flags) & ["+", " ", "#"]).any? ||
          format.fetch(:width).positive? ||
          format.fetch(:width_argument) ||
          !format.fetch(:precision).nil? ||
          format.fetch(:precision_argument) ||
          %w[h hh].include?(format.fetch(:length_modifier))
      end

      def emit_formatted_character(value, count_name, format)
        return emit_dynamic_formatted_character(value, count_name, format) if format.fetch(:width_argument)

        padding = format.fetch(:width_argument) ? "((#{printf_width(format)}) - 1)" : [format.fetch(:width) - 1, 0].max
        lines = []
        lines.concat(counted_padding_lines(padding, count_name)) unless format.fetch(:left_adjust)
        lines << counted_output_line(value, count_name)
        lines.concat(counted_padding_lines(padding, count_name)) if format.fetch(:left_adjust)
        lines
      end

      def emit_dynamic_formatted_character(value, count_name, format)
        prefix = next_printf_format_prefix
        [
          "    {",
          "        int #{prefix}_width = (int)(#{printf_width(format)});",
          "        int #{prefix}_left = (int)(#{printf_left_adjust(format)});",
          "        if (!#{prefix}_left && pf_output_counted_padding(#{prefix}_width - 1, &#{count_name}) != 0) PF_ABORT();",
          "        if (pf_output_counted_cell((unsigned char)(#{value}), &#{count_name}) != 0) PF_ABORT();",
          "        if (#{prefix}_left && pf_output_counted_padding(#{prefix}_width - 1, &#{count_name}) != 0) PF_ABORT();",
          "    }"
        ]
      end

      def emit_formatted_static_bytes(bytes, count_name, format)
        if format.fetch(:width_argument) || format.fetch(:precision_argument)
          return emit_dynamic_formatted_static_bytes(bytes, count_name, format)
        end

        selected = format.fetch(:precision).nil? ? bytes : bytes.take(format.fetch(:precision))
        padding = [format.fetch(:width) - selected.length, 0].max
        lines = []
        lines.concat(counted_padding_lines(padding, count_name)) unless format.fetch(:left_adjust)
        lines.concat(selected.map { |byte| counted_output_line(byte, count_name) })
        lines.concat(counted_padding_lines(padding, count_name)) if format.fetch(:left_adjust)
        lines
      end

      def emit_dynamic_formatted_static_bytes(bytes, count_name, format)
        prefix = next_printf_format_prefix
        lines = [
          "    {",
          "        int #{prefix}_width = (int)(#{printf_width(format)});",
          "        int #{prefix}_precision = (int)(#{printf_precision(format)});",
          "        int #{prefix}_left = (int)(#{printf_left_adjust(format)});",
          "        int #{prefix}_length = (#{prefix}_precision < 0 || #{prefix}_precision > #{bytes.length}) ? #{bytes.length} : #{prefix}_precision;"
        ]
        lines << "        if (!#{prefix}_left && pf_output_counted_padding(#{prefix}_width - #{prefix}_length, &#{count_name}) != 0) PF_ABORT();"
        bytes.each_with_index do |byte, index|
          lines << "        if (#{prefix}_length > #{index} && pf_output_counted_cell((unsigned char)(#{byte}), &#{count_name}) != 0) PF_ABORT();"
        end
        lines << "        if (#{prefix}_left && pf_output_counted_padding(#{prefix}_width - #{prefix}_length, &#{count_name}) != 0) PF_ABORT();"
        lines << "    }"
        lines
      end

      def counted_padding_lines(width, count_name)
        return [] if width.is_a?(Integer) && !width.positive?

        ["    if (pf_output_counted_padding(#{width}, &#{count_name}) != 0) PF_ABORT();"]
      end

      def printf_width(format)
        format.fetch(:width_expression) || format.fetch(:width)
      end

      def printf_precision(format)
        format.fetch(:precision_expression) || (format.fetch(:precision) || -1)
      end

      def printf_left_adjust(format)
        format.fetch(:left_adjust_expression) || printf_bool(format.fetch(:left_adjust))
      end

      def printf_zero_pad(format)
        printf_bool(format.fetch(:zero_pad))
      end

      def printf_sign_mode(format)
        return 1 if format.fetch(:flags).include?("+")
        return 2 if format.fetch(:flags).include?(" ")

        0
      end

      def printf_prefix_mode(specifier, format)
        return 0 unless format.fetch(:flags).include?("#")
        return 1 if specifier == "x"
        return 2 if specifier == "X"
        return 3 if specifier == "o"

        0
      end

      def printf_signed_integer_value(value, bits)
        "((long long)(#{signed_expression(value, bits)}))"
      end

      def printf_unsigned_integer_value(value, bits)
        "((unsigned long long)((#{value}) & #{integer_mask_literal(bits)}))"
      end

      def printf_bool(value)
        value ? 1 : 0
      end

      def next_printf_format_prefix
        name = "pf_printf_fmt_#{@printf_format_index}"
        @printf_format_index += 1
        name
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
        return 16 if length_modifier == "h"
        return 8 if length_modifier == "hh"
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
        stripped = argument.to_s.strip
        return pointer_argument_value(stripped) if stripped.start_with?("ptr ") || stripped.match?(/\A.+?\*\s+/)

        raise Frontend::LLVMSubset::ParseError, "unsupported printf pointer argument: #{argument}"
      end

      def pointer_argument_value(stripped)
        return stripped.delete_prefix("ptr ").strip if stripped.start_with?("ptr ")

        match = stripped.match(/\A.+?\*\s+(.+)\z/)
        return match[1] if match

        stripped.split(/\s+/).last
      end

      def split_call_arguments(raw_arguments)
        arguments = []
        current = +""
        depth = 0

        raw_arguments.each_char do |char|
          case char
          when "(", "[", "<"
            depth += 1
            current << char
          when ")", "]", ">"
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
        match = line.match(/\A(?:(#{NAME})\s*=\s*)?(?:tail\s+|musttail\s+|notail\s+)?call\s+(?:#{ATTRIBUTE_TOKEN}\s+)*(i(?:1|8|16|32|64|128)|<\d+\s+x\s+i(?:1|8|16|32|64)>|ptr|void)\s+(?:\([^)]*\)\s+)?@([-A-Za-z$._0-9]+)\((.*)\)\z/)
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
          if (match = stripped.match(/\A(i(?:1|8|16|32|64|128)|<\d+\s+x\s+i(?:1|8|16|32|64)>)\s+(.+)\z/))
            next({ type: match[1], value: match[2] })
          end
          if stripped.start_with?("ptr ") || stripped.match?(/\A.+?\*\s+/)
            next({ type: "ptr", value: pointer_argument_value(stripped) })
          end
          if stripped.start_with?("metadata ")
            next({ type: "metadata", value: stripped.delete_prefix("metadata ").strip })
          end

          raise Frontend::LLVMSubset::ParseError, "unsupported call argument: #{argument}"
        end
      end

      def validate_call_signature!(call, line)
        return validate_memory_intrinsic_signature!(call) if llvm_memory_intrinsic?(call.fetch(:function_name))
        return validate_noop_intrinsic_signature!(call) if llvm_noop_intrinsic?(call.fetch(:function_name))
        return validate_expect_intrinsic_signature!(call) if llvm_expect_intrinsic?(call.fetch(:function_name))
        return validate_numeric_intrinsic_signature!(call) if llvm_numeric_intrinsic?(call.fetch(:function_name))

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

      def llvm_noop_intrinsic?(name)
        llvm_lifetime_intrinsic?(name) || llvm_assume_intrinsic?(name) || llvm_debug_intrinsic?(name)
      end

      def llvm_lifetime_intrinsic?(name)
        name.start_with?("llvm.lifetime.start.") || name.start_with?("llvm.lifetime.end.")
      end

      def llvm_assume_intrinsic?(name)
        name == "llvm.assume"
      end

      def llvm_debug_intrinsic?(name)
        name.start_with?("llvm.dbg.")
      end

      def llvm_expect_intrinsic?(name)
        name.start_with?("llvm.expect.")
      end

      def llvm_numeric_intrinsic?(name)
        llvm_minmax_intrinsic?(name) || llvm_abs_intrinsic?(name) || llvm_bit_count_intrinsic?(name) || llvm_bswap_intrinsic?(name)
      end

      def llvm_minmax_intrinsic?(name)
        name.match?(/\Allvm\.(?:smax|smin|umax|umin)\.i(?:1|8|16|32|64)\z/)
      end

      def llvm_abs_intrinsic?(name)
        name.match?(/\Allvm\.abs\.i(?:1|8|16|32|64)\z/)
      end

      def llvm_bit_count_intrinsic?(name)
        name.match?(/\Allvm\.(?:ctpop|ctlz|cttz)\.i(?:1|8|16|32|64)\z/)
      end

      def llvm_bswap_intrinsic?(name)
        name.match?(/\Allvm\.bswap\.i(?:16|32|64)\z/)
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

      def validate_noop_intrinsic_signature!(call)
        name = call.fetch(:function_name)
        unless call.fetch(:return_type) == "void"
          raise Frontend::LLVMSubset::ParseError, "call return type mismatch for @#{name}: expected void, got #{call.fetch(:return_type)}"
        end
        if call.fetch(:destination)
          raise Frontend::LLVMSubset::ParseError, "void call cannot assign a result: @#{name}"
        end

        return if llvm_debug_intrinsic?(name)

        arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
        if llvm_assume_intrinsic?(name)
          validate_memory_intrinsic_arguments!(name, arguments, ["i1"])
        else
          validate_memory_intrinsic_arguments!(name, arguments, [%w[i32 i64], "ptr"])
        end
      end

      def validate_expect_intrinsic_signature!(call)
        name = call.fetch(:function_name)
        arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
        if arguments.length != 2
          raise Frontend::LLVMSubset::ParseError, "wrong argument count for @#{name}: expected 2, got #{arguments.length}"
        end
        unless call.fetch(:destination)
          raise Frontend::LLVMSubset::ParseError, "non-void call must assign a result: @#{name}"
        end
        expected_type = call.fetch(:return_type)
        unless arguments.all? { |argument| argument.fetch(:type) == expected_type }
          raise Frontend::LLVMSubset::ParseError, "call argument type mismatch for @#{name}: expected #{expected_type}"
        end
      end

      def emit_expect_intrinsic(call, context: nil)
        argument = parse_typed_call_arguments(call.fetch(:raw_arguments)).fetch(0)
        bits = argument.fetch(:type).delete_prefix("i").to_i
        value = context ? inline_value(argument.fetch(:value), context) : llvm_value(argument.fetch(:value))
        target = context ? inline_register(context, call.fetch(:destination)) : register(call.fetch(:destination))
        ["    #{target} = #{unsigned_cast(bits)}((#{value}) & #{integer_mask_literal(bits)});"]
      end

      def validate_numeric_intrinsic_signature!(call)
        name = call.fetch(:function_name)
        bits = name[/\.i(1|8|16|32|64)\z/, 1]&.to_i
        unless bits && call.fetch(:return_type) == "i#{bits}"
          raise Frontend::LLVMSubset::ParseError, "call return type mismatch for @#{name}: expected i#{bits}, got #{call.fetch(:return_type)}"
        end

        arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
        expected = if llvm_abs_intrinsic?(name) || name.include?(".ctlz.") || name.include?(".cttz.")
                     ["i#{bits}", "i1"]
                   elsif llvm_bit_count_intrinsic?(name) || llvm_bswap_intrinsic?(name)
                     ["i#{bits}"]
                   else
                     ["i#{bits}", "i#{bits}"]
                   end
        validate_memory_intrinsic_arguments!(name, arguments, expected)
        unless call.fetch(:destination)
          raise Frontend::LLVMSubset::ParseError, "numeric intrinsic must assign a result: @#{name}"
        end
      end

      def emit_numeric_intrinsic_call(call, context: nil)
        name = call.fetch(:function_name)
        bits = name[/\.i(1|8|16|32|64)\z/, 1].to_i
        arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
        left = scalar_value(arguments.fetch(0).fetch(:value), context:)
        expression = if llvm_abs_intrinsic?(name)
                       abs_expression(bits, left)
                     elsif llvm_bswap_intrinsic?(name)
                       bswap_expression(bits, left)
                     elsif llvm_bit_count_intrinsic?(name)
                       bit_count_expression(name, bits, left)
                     else
                       right = scalar_value(arguments.fetch(1).fetch(:value), context:)
                       minmax_expression(name, bits, left, right)
                     end
        target = context ? inline_register(context, call.fetch(:destination)) : register(call.fetch(:destination))
        ["    #{target} = #{unsigned_cast(bits)}((#{expression}) & #{integer_mask_literal(bits)});"]
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
          *dynamic_valid_address_lines(destination),
          *dynamic_writable_address_lines(destination),
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
          *dynamic_valid_address_lines(destination),
          *dynamic_valid_address_lines(source),
          *dynamic_writable_address_lines(destination),
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
          *dynamic_valid_address_lines(destination),
          *dynamic_valid_address_lines(source),
          *dynamic_writable_address_lines(destination),
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
        if (match = raw_pointer.match(/getelementptr(?:\s+(?:inbounds|nuw|nusw|inrange))*\s*\(\[(\d+)\s+x\s+i8\],\s+ptr(?:\s+addrspace\(\d+\))?\s+(#{GLOBAL_NAME}),\s+i\d+\s+(-?\d+),\s+i\d+\s+(-?\d+)\)/))
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

      def inline_pointer_expr(context, name)
        memory_address(name, context:).offset
      end

      def pointer_expr(name)
        memory_address(name).offset
      end

      def memory_address(name, context: nil)
        stripped = strip_value_attributes(name.to_s.strip)
        return encoded_memory_address("0ull") if stripped == "null"

        constant = constant_gep_pointer(stripped, context:)
        if constant
          return encoded_memory_address(constant.value) if constant.is_a?(EncodedPointer)
          return MemoryAddress.new(limit: "PF_LLVM_GLOBAL_MEMORY_SIZE", memory: "llvm_global_memory", name: constant.name, readonly: !global_numeric_mutability.fetch(constant.name, false), readonly_expression: nil, offset: constant.offset) if constant.is_a?(GlobalMemoryPointer)
          return MemoryAddress.new(limit: "PF_LLVM_STRING_MEMORY_SIZE", memory: "llvm_string_memory", name: constant.name, offset: global_string_offset_expression(constant), readonly: true) if constant.is_a?(GlobalStringPointer)

          return MemoryAddress.new(limit: "PF_LLVM_MEMORY_SIZE", memory: "llvm_memory", offset: constant, readonly: false)
        end

        pointer = if global_strings.key?(stripped)
                    GlobalStringPointer.new(name: stripped, offset: 0)
                  else
                    if external_global_declaration?(stripped)
                      raise Frontend::LLVMSubset::ParseError, "unsupported external global reference: #{stripped}"
                    end
                    resolve_pointer(stripped, context:)
                  end
        return encoded_memory_address(pointer.value) if pointer.is_a?(EncodedPointer)

        if pointer.is_a?(GlobalStringPointer)
          return MemoryAddress.new(
            limit: "PF_LLVM_STRING_MEMORY_SIZE",
            memory: "llvm_string_memory",
            name: pointer.name,
            offset: global_string_offset_expression(pointer),
            readonly: true
          )
        end
        if pointer.is_a?(GlobalMemoryPointer)
          return MemoryAddress.new(
            limit: "PF_LLVM_GLOBAL_MEMORY_SIZE",
            memory: "llvm_global_memory",
            name: pointer.name,
            readonly: !global_numeric_mutability.fetch(pointer.name, false),
            readonly_expression: nil,
            offset: pointer.offset
          )
        end

        MemoryAddress.new(limit: "PF_LLVM_MEMORY_SIZE", memory: "llvm_memory", offset: pointer, readonly: false)
      end

      def encoded_memory_address(encoded)
        MemoryAddress.new(
          invalid_expression: nil,
          limit: "(((#{encoded}) & PF_LLVM_STRING_POINTER_TAG) != 0ull ? PF_LLVM_STRING_MEMORY_SIZE : (((#{encoded}) & PF_LLVM_GLOBAL_POINTER_TAG) != 0ull ? PF_LLVM_GLOBAL_MEMORY_SIZE : PF_LLVM_MEMORY_SIZE))",
          memory: "(((#{encoded}) & PF_LLVM_STRING_POINTER_TAG) != 0ull ? llvm_string_memory : (((#{encoded}) & PF_LLVM_GLOBAL_POINTER_TAG) != 0ull ? llvm_global_memory : llvm_memory))",
          name: encoded,
          offset: "((#{encoded}) & PF_LLVM_POINTER_OFFSET_MASK)",
          readonly: false,
          readonly_expression: "(((#{encoded}) & PF_LLVM_READONLY_POINTER_TAG) != 0ull)"
        )
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
        elsif address.memory == "llvm_string_memory"
          EncodedPointer.new(value: "((unsigned long long)(#{offset}) | PF_LLVM_GLOBAL_POINTER_TAG | PF_LLVM_READONLY_POINTER_TAG | PF_LLVM_STRING_POINTER_TAG)")
        elsif address.readonly_expression && address.name
          tags = "((#{address.name}) & (PF_LLVM_GLOBAL_POINTER_TAG | PF_LLVM_READONLY_POINTER_TAG | PF_LLVM_STRING_POINTER_TAG))"
          EncodedPointer.new(value: "((unsigned long long)(#{offset}) | #{tags})")
        else
          offset
        end
      end

      def ensure_writable_address!(address)
        return unless address.readonly

        raise Frontend::LLVMSubset::ParseError, "cannot write to constant global: #{address.name}"
      end

      def dynamic_writable_address_lines(address)
        return [] unless address.readonly_expression

        [
          "    if (#{address.readonly_expression}) {",
          "        fprintf(stderr, \"pfc runtime error: LLVM write to constant global through pointer\\n\");",
          "        PF_ABORT();",
          "    }"
        ]
      end

      def dynamic_valid_address_lines(address)
        return [] unless address.invalid_expression

        [
          "    if (#{address.invalid_expression}) {",
          "        fprintf(stderr, \"pfc runtime error: LLVM string pointer dereference is unsupported\\n\");",
          "        PF_ABORT();",
          "    }"
        ]
      end

      def encoded_pointer_value(raw, context: nil)
        stripped = strip_value_attributes(raw)
        return "0ull" if stripped == "null"
        return encoded_pointer_value(Regexp.last_match(1), context:) if stripped.match(/\Aptrtoint\s*\(ptr\s+(.+?)\s+to\s+i(?:1|8|16|32|64)\)\z/)

        pointer = pointer_binding(stripped, context:)
        return pointer.value if pointer.is_a?(EncodedPointer)
        return "((unsigned long long)(#{pointer}))" unless pointer.is_a?(GlobalMemoryPointer) || pointer.is_a?(GlobalStringPointer)

        if pointer.is_a?(GlobalStringPointer)
          offset = global_string_offset_expression(pointer)
          return "((unsigned long long)(#{offset}) | PF_LLVM_GLOBAL_POINTER_TAG | PF_LLVM_READONLY_POINTER_TAG | PF_LLVM_STRING_POINTER_TAG)"
        end

        tags = ["PF_LLVM_GLOBAL_POINTER_TAG"]
        tags << "PF_LLVM_READONLY_POINTER_TAG" unless global_numeric_mutability.fetch(pointer.name, false)
        "((unsigned long long)(#{pointer.offset}) | #{tags.join(' | ')})"
      end

      def pointer_binding(raw, context: nil)
        stripped = strip_value_attributes(raw)
        raise Frontend::LLVMSubset::ParseError, "unsupported blockaddress constant expression: #{stripped}" if stripped.start_with?("blockaddress")

        if stripped.match(/\A(?:bitcast|addrspacecast)\s*\((?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\s+(.+?)\s+to\s+.+\)\z/)
          return pointer_binding(Regexp.last_match(1), context:)
        end
        if stripped.match(/\Ainttoptr\s*\(i(?:1|8|16|32|64)\s+(.+?)\s+to\s+ptr(?:\s+addrspace\(\d+\))?\)\z/)
          value = Regexp.last_match(1)
          return pointer_binding(Regexp.last_match(1), context:) if value.match(/\Aptrtoint\s*\(ptr\s+(.+?)\s+to\s+i(?:1|8|16|32|64)\)\z/)

          return EncodedPointer.new(value:)
        end
        constant = constant_gep_pointer(stripped, context:)
        return constant if constant

        token = stripped.split(/\s+/).last
        return EncodedPointer.new(value: "0ull") if token == "null"
        return GlobalStringPointer.new(name: token, offset: 0) if global_strings.key?(token)
        if external_global_declaration?(token)
          raise Frontend::LLVMSubset::ParseError, "unsupported external global reference: #{token}"
        end

        resolve_pointer(token, context:)
      end

      def external_global_declaration?(name)
        source.each_line.any? do |line|
          line.sub(/;.*/, "").strip.match?(/\A#{Regexp.escape(name)}\s*=.*?\bexternal\s+(?:global|constant)\b/)
        end
      end

      def strip_value_attributes(raw)
        stripped = raw.to_s.strip
        loop do
          updated = stripped
          updated = updated.sub(/\A(?:noundef|nonnull|noalias|readonly|writeonly|returned|nocapture)\s+/, "")
          updated = updated.sub(/\A(?:dereferenceable|dereferenceable_or_null|align|captures)\([^)]*\)\s+/, "")
          updated = updated.sub(/\Aalign\s+\d+\s+/, "")
          break stripped if updated == stripped

          stripped = updated
        end
      end

      def constant_gep_pointer(raw, context:)
        match = raw.match(/\Agetelementptr(?:\s+(?:inbounds|nuw|nusw|inrange))*\s*\((.+?),\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\s+(#{POINTER_NAME}),\s+(.+)\)\z/)
        return nil unless match

        source_type = match[1]
        base = match[2]
        index_arguments = Frontend::LLVMSubset::Parser::Instruction.split_arguments(match[3])
        indices = index_arguments.map { |argument| argument.split(/\s+/, 2).last }
        base_address = memory_address(base, context:)
        offset = gep_offset_expression(source_type, indices, base_address.offset, context:)
        pointer_from_address(base_address, offset)
      end

      def global_string_offset_expression(pointer)
        base = global_string_offsets.fetch(pointer.name)
        return base + pointer.offset if pointer.offset.is_a?(Integer)

        "(#{base} + (#{pointer.offset}))"
      end

      def register(name)
        registers.fetch(name) { raise Frontend::LLVMSubset::ParseError, "unknown register: #{name}" }
      end

      def i128_high_register(name, context: nil)
        high_registers = context ? context.fetch(:i128_high_values) : i128_high_registers
        high_registers.fetch(name) { raise Frontend::LLVMSubset::ParseError, "unknown i128 register: #{name}" }
      end

      def alloca?(line)
        line.match?(/\A#{NAME}\s*=\s*alloca\b/)
      end

      def phi?(line)
        line.match?(/\A#{NAME}\s*=\s*phi\b/)
      end

      def debug_record?(line)
        line.to_s.match?(/\A#dbg_[A-Za-z0-9_.]+\b/)
      end

      def unsupported_instruction_message(line)
        opcode = line.to_s[/\A(?:#{NAME}\s*=\s*)?([A-Za-z0-9_.]+)/, 1] || "unknown"
        return "unsupported scalable vector type in LLVM instruction #{opcode}: #{line}" if line.to_s.match?(/(?:^|\s)<vscale\s+x\s+/)
        return "unsupported vector type in LLVM instruction #{opcode}: #{line}" if line.to_s.match?(/(?:^|\s)<\d+\s+x\s+(?!i(?:1|8|16|32|64)\b)[^>]+>/)
        return "unsupported floating-point type in LLVM instruction #{opcode}: #{line}" if line.to_s.match?(/\b(?:half|float|double|fp128|x86_fp80|ppc_fp128)\b/)
        return "unsupported i128 type in LLVM instruction #{opcode}: #{line}" if line.to_s.match?(/\bi128\b/)
        return "unsupported blockaddress constant expression: #{line}" if line.to_s.include?("blockaddress")

        "unsupported LLVM instruction #{opcode}: #{line}. Run `pfc llvm-capabilities` for the supported subset or `pfc llvm-capabilities --check FILE.ll` to preflight a file."
      end

      def c_label(label)
        "pf_block_#{label.gsub(/[^A-Za-z0-9_]/, '_')}"
      end

      def c_value_name(name)
        "pf_v_#{name.delete_prefix('%').gsub(/[^A-Za-z0-9_]/, '_')}"
      end

      def c_aggregate_name(name)
        "pf_a_#{name.delete_prefix('%').gsub(/[^A-Za-z0-9_]/, '_')}"
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
        lines = []
        if address.invalid_expression
          lines.concat([
            "    if (#{address.invalid_expression}) {",
            "        fprintf(stderr, \"pfc runtime error: LLVM string pointer dereference is unsupported\\n\");",
            "        PF_ABORT();",
            "    }"
          ])
        end
        lines + [
          "    pf_slot_index = (int)(#{address.offset});",
          "    if (pf_slot_index < 0 || pf_slot_index + #{width} > #{address.limit}) {",
          "        fprintf(stderr, \"pfc runtime error: LLVM memory access out of range: %d\\n\", pf_slot_index);",
          "        PF_ABORT();",
          "    }"
        ]
      end

      def inline_slot_lines(address, width)
        lines = []
        if address.invalid_expression
          lines.concat([
            "    if (#{address.invalid_expression}) {",
            "        fprintf(stderr, \"pfc runtime error: LLVM string pointer dereference is unsupported\\n\");",
            "        PF_ABORT();",
            "    }"
          ])
        end
        lines + [
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

      def minmax_expression(name, bits, left, right)
        signed = name.include?(".smax.") || name.include?(".smin.")
        minimum = name.include?("min")
        left_compare = signed ? signed_expression(left, bits) : left
        right_compare = signed ? signed_expression(right, bits) : right
        operator = minimum ? "<" : ">"
        "((#{left_compare}) #{operator} (#{right_compare}) ? (#{left}) : (#{right}))"
      end

      def abs_expression(bits, value)
        "(((#{value}) & #{sign_bit_literal(bits)}) ? ((~(#{value}) + 1ull) & #{integer_mask_literal(bits)}) : ((#{value}) & #{integer_mask_literal(bits)}))"
      end

      def bswap_expression(bits, value)
        byte_count = byte_width(bits)
        terms = byte_count.times.map do |index|
          source_shift = index * 8
          target_shift = (byte_count - index - 1) * 8
          "(((#{value}) >> #{source_shift}) & 255ull) << #{target_shift}"
        end
        "(#{terms.join(') | (')})"
      end

      def bit_count_expression(name, bits, value)
        masked = "((#{value}) & #{integer_mask_literal(bits)})"
        if name.include?(".ctpop.")
          terms = bits.times.map { |index| "((#{masked} >> #{index}) & 1ull)" }
          return "(#{terms.join(' + ')})"
        end

        if name.include?(".ctlz.")
          terms = bits.times.map do |count|
            bit = bits - count - 1
            condition = count.zero? ? "((#{masked} >> #{bit}) & 1ull)" : "((#{masked} >> #{bit}) & 1ull)"
            "#{condition} ? #{count}ull"
          end
          return "(#{terms.join(' : ')} : #{bits}ull)"
        end

        terms = bits.times.map do |count|
          condition = "((#{masked} >> #{count}) & 1ull)"
          "#{condition} ? #{count}ull"
        end
        "(#{terms.join(' : ')} : #{bits}ull)"
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
