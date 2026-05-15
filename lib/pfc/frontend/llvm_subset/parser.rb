# frozen_string_literal: true

require_relative "../llvm_subset"
require_relative "normalizer"

module PFC
  module Frontend
    class LLVMSubset
      class Parser
        NAME = /%[-A-Za-z$._0-9]+/
        GLOBAL_NAME = /@[-A-Za-z$._0-9]+/
        POINTER_NAME = /(?:#{NAME}|#{GLOBAL_NAME})/
        INTEGER_TYPE = /i(?:1|8|16|32|64)/
        VECTOR_TYPE = /<\d+\s+x\s+i(?:1|8|16|32|64)>/
        RETURN_TYPE = /(?:#{INTEGER_TYPE}|i128|#{VECTOR_TYPE}|ptr|void)/
        ATTRIBUTE_TOKEN = /[-\w]+(?:\([^)]*\))?/

        class Instruction
          attr_reader :kind, :source_line, :text

          def self.build(text, source_line: nil)
            instruction = new(text)
            built = case instruction.kind
            when :call then CallInstruction.new(text)
            when :branch then BranchInstruction.new(text)
            when :gep then GEPInstruction.new(text)
            when :load then LoadInstruction.new(text)
            when :store then StoreInstruction.new(text)
            when :binary then BinaryInstruction.new(text)
            when :icmp then ICmpInstruction.new(text)
            when :select then SelectInstruction.new(text)
            when :cast then CastInstruction.new(text)
            when :freeze then FreezeInstruction.new(text)
            when :extractelement then ExtractElementInstruction.new(text)
            when :insertelement then InsertElementInstruction.new(text)
            when :extractvalue then ExtractValueInstruction.new(text)
            when :insertvalue then InsertValueInstruction.new(text)
            when :switch then SwitchInstruction.new(text)
            when :phi then PhiInstruction.new(text)
            when :return then ReturnInstruction.new(text)
            else instruction
            end
            built.instance_variable_set(:@source_line, source_line)
            built
          end

          def initialize(text)
            @text = text.freeze
            @kind = classify(text)
          end

          def ==(other)
            other_text = other.is_a?(Instruction) ? other.text : other
            text == other_text
          end

          def to_s
            text
          end

          def to_str
            text
          end

          def inspect
            text.inspect
          end

          def match(...)
            text.match(...)
          end

          def match?(...)
            text.match?(...)
          end

          def include?(...)
            text.include?(...)
          end

          def start_with?(...)
            text.start_with?(...)
          end

          def [](...)
            text.[](...)
          end

          def scan(...)
            text.scan(...)
          end

          def split(...)
            text.split(...)
          end

          def self.split_arguments(raw)
            arguments = []
            current = +""
            depth = 0

            raw.each_char do |char|
              case char
              when "(", "[", "<", "{"
                depth += 1
                current << char
              when ")", "]", ">", "}"
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

          private

          def classify(text)
            return :phi if text.match?(/\A#{NAME}\s*=\s*phi\b/)
            return :call if text.include?("call ")
            return :alloca if text.match?(/\A#{NAME}\s*=\s*alloca\b/)
            return :store if text.start_with?("store ")
            return :load if text.include?(" load ")
            return :binary if text.match?(/\A#{NAME}\s*=\s*(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)\b/)
            return :select if text.match?(/\A#{NAME}\s*=\s*select\b/)
            return :cast if text.match?(/\A#{NAME}\s*=\s*(zext|sext|trunc|ptrtoint|inttoptr|bitcast|addrspacecast)\b/)
            return :freeze if text.match?(/\A#{NAME}\s*=\s*freeze\b/)
            return :gep if text.match?(/\A#{NAME}\s*=\s*getelementptr\b/)
            return :extractelement if text.match?(/\A#{NAME}\s*=\s*extractelement\b/)
            return :insertelement if text.match?(/\A#{NAME}\s*=\s*insertelement\b/)
            return :extractvalue if text.match?(/\A#{NAME}\s*=\s*extractvalue\b/)
            return :insertvalue if text.match?(/\A#{NAME}\s*=\s*insertvalue\b/)
            return :icmp if text.match?(/\A#{NAME}\s*=\s*icmp\b/)
            return :switch if text.start_with?("switch ")
            return :branch if text.start_with?("br ")
            return :return if text.start_with?("ret ")
            return :unreachable if text == "unreachable"

            :unknown
          end
        end

        class CallInstruction < Instruction
          attr_reader :arguments, :destination, :function_name, :return_type

          def initialize(text)
            super
            match = text.match(/\A(?:(#{NAME})\s*=\s*)?call\s+(?:#{ATTRIBUTE_TOKEN}\s+)*(#{RETURN_TYPE})\s+(?:\([^)]*\)\s+)?@([-A-Za-z$._0-9]+)\((.*)\)\z/)
            return unless match

            @destination = match[1]
            @return_type = match[2]
            @function_name = match[3]
            @arguments = Instruction.split_arguments(match[4]).freeze
          end
        end

        class BranchInstruction < Instruction
          attr_reader :condition, :targets

          def initialize(text)
            super
            if (match = text.match(/\Abr\s+label\s+%([-A-Za-z$._0-9]+)\z/))
              @condition = nil
              @targets = [match[1]].freeze
              return
            end

            match = text.match(/\Abr\s+i1\s+(.+?),\s+label\s+%([-A-Za-z$._0-9]+),\s+label\s+%([-A-Za-z$._0-9]+)\z/)
            return unless match

            @condition = match[1]
            @targets = [match[2], match[3]].freeze
          end
        end

        class GEPInstruction < Instruction
          attr_reader :array_count, :base_pointer, :destination, :element_bits, :inbounds, :indices, :source_type

          def initialize(text)
            super
            match = text.match(/\A(#{NAME})\s*=\s*getelementptr((?:\s+(?:inbounds|nuw|nusw|inrange))*)\s+(.+?),\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\s+(?:.+\s+)?(#{POINTER_NAME}),\s+(.+)\z/)
            return unless match

            @destination = match[1]
            @inbounds = !match[2].nil?
            @source_type = match[3]
            @base_pointer = match[4]
            @indices = Instruction.split_arguments(match[5]).map { |argument| argument.split(/\s+/, 2).last }.freeze
            if (array_match = source_type.match(/\A\[(\d+)\s+x\s+i(1|8|16|32|64)\]\z/))
              @array_count = array_match[1].to_i
              @element_bits = array_match[2].to_i
            elsif (scalar_match = source_type.match(/\Ai(1|8|16|32|64)\z/))
              @array_count = nil
              @element_bits = scalar_match[1].to_i
            end
          end
        end

        class LoadInstruction < Instruction
          attr_reader :bits, :destination, :pointer, :value_type

          def initialize(text)
            super
            match = text.match(/\A(#{NAME})\s*=\s*load\s+(.+?),\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\s+(.+?)(?:,\s+align\s+\d+)?\z/)
            return unless match

            @destination = match[1]
            @value_type = (match[2] == "ptr" || match[2].start_with?("ptr addrspace(") || match[2].end_with?("*")) ? "ptr" : match[2]
            @bits = @value_type.delete_prefix("i").to_i if @value_type.match?(/\Ai(?:1|8|16|32|64|128)\z/)
            @pointer = match[3].strip
          end
        end

        class StoreInstruction < Instruction
          attr_reader :bits, :pointer, :value, :value_type

          def initialize(text)
            super
            match = text.match(/\Astore\s+(.+?)\s+(.+?),\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\s+(.+?)(?:,\s+align\s+\d+)?\z/)
            return unless match

            @value_type = (match[1] == "ptr" || match[1].start_with?("ptr addrspace(") || match[1].end_with?("*")) ? "ptr" : match[1]
            @bits = @value_type.delete_prefix("i").to_i if @value_type.match?(/\Ai(?:1|8|16|32|64|128)\z/)
            @value = match[2]
            @pointer = match[3].strip
          end
        end

        class BinaryInstruction < Instruction
          attr_reader :bits, :destination, :flags, :left, :operator, :right, :value_type, :vector_type

          def initialize(text)
            super
            if (match = text.match(/\A(#{NAME})\s*=\s*(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)((?:\s+(?:nuw|nsw|exact))*)\s+(<\d+\s+x\s+i(8|16|32|64)>)\s+(.+)\z/))
              operands = Instruction.split_arguments(match[6])
              return unless operands.length == 2

              @destination = match[1]
              @operator = match[2]
              @flags = match[3].split.freeze
              @value_type = match[4]
              @vector_type = match[4]
              @bits = vector_type[/i(8|16|32|64)>/, 1].to_i
              @left = operands.fetch(0)
              @right = operands.fetch(1)
              return
            end

            if (match = text.match(/\A(#{NAME})\s*=\s*(add|sub|and|or|xor|shl|lshr|ashr)\s+i128\s+(.+?),\s+(.+)\z/))
              @destination = match[1]
              @operator = match[2]
              @flags = [].freeze
              @value_type = "i128"
              @bits = 128
              @left = match[3]
              @right = match[4]
              return
            end

            match = text.match(/\A(#{NAME})\s*=\s*(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)((?:\s+(?:nuw|nsw|exact))*)\s+i(1|8|16|32|64)\s+(.+?),\s+(.+)\z/)
            return unless match

            @destination = match[1]
            @operator = match[2]
            @flags = match[3].split.freeze
            @value_type = "i#{match[4]}"
            @bits = match[4].to_i
            @left = match[5]
            @right = match[6]
          end
        end

        class ICmpInstruction < Instruction
          attr_reader :bits, :destination, :left, :operand_type, :operand_vector_type, :predicate, :right, :vector_type

          def initialize(text)
            super
            if (match = text.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne|ugt|uge|ult|ule|sgt|sge|slt|sle)\s+(<\d+\s+x\s+i(1|8|16|32|64)>)\s+(.+)\z/))
              operands = Instruction.split_arguments(match[5])
              return unless operands.length == 2

              @destination = match[1]
              @predicate = match[2]
              @bits = match[4].to_i
              @operand_type = match[3]
              @operand_vector_type = match[3]
              @vector_type = match[3].sub(/i(?:1|8|16|32|64)>\z/, "i1>")
              @left = operands.fetch(0)
              @right = operands.fetch(1)
              return
            end

            if (match = text.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne|ugt|uge|ult|ule|sgt|sge|slt|sle)\s+i128\s+(.+?),\s+(.+)\z/))
              @destination = match[1]
              @predicate = match[2]
              @bits = 128
              @operand_type = "i128"
              @left = match[3]
              @right = match[4]
              return
            end

            if (match = text.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne|ugt|uge|ult|ule|sgt|sge|slt|sle)\s+i(1|8|16|32|64)\s+(.+?),\s+(.+)\z/))
              @destination = match[1]
              @predicate = match[2]
              @bits = match[3].to_i
              @operand_type = "i#{match[3]}"
              @left = match[4]
              @right = match[5]
              return
            end

            match = text.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne)\s+ptr\s+(.+?),\s+(.+)\z/)
            return unless match

            @destination = match[1]
            @predicate = match[2]
            @operand_type = "ptr"
            @left = match[3]
            @right = match[4]
          end
        end

        class SelectInstruction < Instruction
          attr_reader :bits, :condition, :condition_type, :destination, :false_value, :true_value, :value_type, :vector_type

          def initialize(text)
            super
            if (match = text.match(/\A(#{NAME})\s*=\s*select\s+(<\d+\s+x\s+i1>)\s+(.+)\z/))
              operands = Instruction.split_arguments(match[3])
              return unless operands.length == 3
              true_match = operands.fetch(1).match(/\A(<\d+\s+x\s+i(1|8|16|32|64)>)\s+(.+)\z/)
              false_match = operands.fetch(2).match(/\A#{Regexp.escape(true_match[1])}\s+(.+)\z/) if true_match
              return unless true_match && false_match

              @destination = match[1]
              @condition_type = match[2]
              @condition = operands.fetch(0)
              @bits = true_match[2].to_i
              @value_type = true_match[1]
              @vector_type = true_match[1]
              @true_value = true_match[3]
              @false_value = false_match[1]
              return
            end

            if (match = text.match(/\A(#{NAME})\s*=\s*select\s+i1\s+(.+?),\s+i128\s+(.+?),\s+i128\s+(.+)\z/))
              @destination = match[1]
              @condition = match[2]
              @bits = 128
              @value_type = "i128"
              @true_value = match[3]
              @false_value = match[4]
              return
            end

            if (match = text.match(/\A(#{NAME})\s*=\s*select\s+i1\s+(.+?),\s+i(1|8|16|32|64)\s+(.+?),\s+i(?:1|8|16|32|64)\s+(.+)\z/))
              @destination = match[1]
              @condition = match[2]
              @bits = match[3].to_i
              @value_type = "i#{match[3]}"
              @true_value = match[4]
              @false_value = match[5]
              return
            end

            match = text.match(/\A(#{NAME})\s*=\s*select\s+i1\s+(.+?),\s+ptr\s+(.+?),\s+ptr\s+(.+)\z/)
            return unless match

            @destination = match[1]
            @condition = match[2]
            @value_type = "ptr"
            @true_value = match[3]
            @false_value = match[4]
          end
        end

        class CastInstruction < Instruction
          attr_reader :destination, :from_bits, :from_type, :operator, :to_bits, :to_type, :value

          def initialize(text)
            super
            if (match = text.match(/\A(#{NAME})\s*=\s*(zext|sext|trunc)\s+i(1|8|16|32|64|128)\s+(.+?)\s+to\s+i(1|8|16|32|64|128)\z/))
              @destination = match[1]
              @operator = match[2]
              @from_bits = match[3].to_i
              @from_type = "i#{match[3]}"
              @value = match[4]
              @to_bits = match[5].to_i
              @to_type = "i#{match[5]}"
              return
            end

            if (match = text.match(/\A(#{NAME})\s*=\s*ptrtoint\s+(?:ptr|.+?\*)\s+(.+?)\s+to\s+i(1|8|16|32|64)\z/))
              @destination = match[1]
              @operator = "ptrtoint"
              @from_type = "ptr"
              @value = match[2]
              @to_bits = match[3].to_i
              @to_type = "i#{match[3]}"
              return
            end

            if (match = text.match(/\A(#{NAME})\s*=\s*bitcast\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\s+(.+?)\s+to\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\z/))
              @destination = match[1]
              @operator = "bitcast"
              @from_type = "ptr"
              @value = match[2]
              @to_type = "ptr"
              return
            end

            if (match = text.match(/\A(#{NAME})\s*=\s*addrspacecast\s+(ptr(?:\s+addrspace\(\d+\))?|.+?\*)\s+(.+?)\s+to\s+(.+)\z/))
              @destination = match[1]
              @operator = "addrspacecast"
              @from_type = match[2]
              @value = match[3]
              @to_type = match[4]
              return
            end

            match = text.match(/\A(#{NAME})\s*=\s*inttoptr\s+i(1|8|16|32|64)\s+(.+?)\s+to\s+(?:ptr(?:\s+addrspace\(\d+\))?|.+?\*)\z/)
            return unless match

            @destination = match[1]
            @operator = "inttoptr"
            @from_bits = match[2].to_i
            @from_type = "i#{match[2]}"
            @value = match[3]
            @to_type = "ptr"
          end
        end

        class FreezeInstruction < Instruction
          attr_reader :bits, :destination, :value, :value_type

          def initialize(text)
            super
            match = text.match(/\A(#{NAME})\s*=\s*freeze\s+(.+?)\s+(.+)\z/)
            return unless match

            @destination = match[1]
            @value_type = pointer_type?(match[2]) ? "ptr" : match[2]
            @bits = @value_type.match(/\Ai(1|8|16|32|64)\z/)&.[](1)&.to_i
            @value = match[3]
          end

          private

          def pointer_type?(type)
            type == "ptr" || type.end_with?("*")
          end
        end

        class ExtractElementInstruction < Instruction
          attr_reader :bits, :destination, :index, :vector, :vector_type

          def initialize(text)
            super
            match = text.match(/\A(#{NAME})\s*=\s*extractelement\s+(<\d+\s+x\s+i(?:1|8|16|32|64)>)\s+(.+)\z/)
            return unless match
            operands = Instruction.split_arguments(match[3])
            return unless operands.length == 2
            index_match = operands.fetch(1).match(/\Ai(?:32|64)\s+(.+)\z/)
            return unless index_match

            @destination = match[1]
            @vector_type = match[2]
            @vector = operands.fetch(0)
            @index = index_match[1]
            @bits = vector_type[/i(1|8|16|32|64)>/, 1].to_i
          end
        end

        class InsertElementInstruction < Instruction
          attr_reader :bits, :destination, :index, :value, :vector, :vector_type

          def initialize(text)
            super
            match = text.match(/\A(#{NAME})\s*=\s*insertelement\s+(<\d+\s+x\s+i(?:1|8|16|32|64)>)\s+(.+)\z/)
            return unless match
            operands = Instruction.split_arguments(match[3])
            return unless operands.length == 3
            value_match = operands.fetch(1).match(/\Ai(1|8|16|32|64)\s+(.+)\z/)
            index_match = operands.fetch(2).match(/\Ai(?:32|64)\s+(.+)\z/)
            return unless value_match && index_match

            @destination = match[1]
            @vector_type = match[2]
            @vector = operands.fetch(0)
            @bits = value_match[1].to_i
            @value = value_match[2]
            @index = index_match[1]
          end
        end

        class ExtractValueInstruction < Instruction
          attr_reader :aggregate, :aggregate_type, :destination, :indices

          def initialize(text)
            super
            match = text.match(/\A(#{NAME})\s*=\s*extractvalue\s+(.+?)\s+(#{NAME}),\s+(.+)\z/)
            return unless match

            @destination = match[1]
            @aggregate_type = match[2]
            @aggregate = match[3]
            @indices = Instruction.split_arguments(match[4]).map(&:to_i).freeze
          end
        end

        class InsertValueInstruction < Instruction
          attr_reader :aggregate, :aggregate_type, :destination, :indices, :insert_type, :value

          def initialize(text)
            super
            match = text.match(/\A(#{NAME})\s*=\s*insertvalue\s+(.+?)\s+(#{NAME}|zeroinitializer|undef|poison),\s+(.+?)\s+(.+?),\s+(.+)\z/)
            return unless match

            @destination = match[1]
            @aggregate_type = match[2]
            @aggregate = match[3]
            @insert_type = match[4]
            @value = match[5]
            @indices = Instruction.split_arguments(match[6]).map(&:to_i).freeze
          end
        end

        class SwitchInstruction < Instruction
          attr_reader :bits, :cases, :default_label, :value

          def initialize(text)
            super
            match = text.match(/\Aswitch\s+i(1|8|16|32|64)\s+(.+?),\s+label\s+%([-A-Za-z$._0-9]+)\s+\[(.*)\]\z/)
            return unless match

            @bits = match[1].to_i
            @value = match[2]
            @default_label = match[3]
            @cases = match[4].scan(/i(?:1|8|16|32|64)\s+(-?\d+),\s+label\s+%([-A-Za-z$._0-9]+)/).map do |case_value, label|
              [case_value, label]
            end.freeze
          end
        end

        class PhiInstruction < Instruction
          attr_reader :bits, :destination, :incoming, :value_type, :vector_type

          def initialize(text)
            super
            if (match = text.match(/\A(#{NAME})\s*=\s*phi\s+(<\d+\s+x\s+i(?:1|8|16|32|64)>)\s+(.+)\z/))
              @destination = match[1]
              @bits = match[2][/i(1|8|16|32|64)>/, 1].to_i
              @value_type = match[2]
              @vector_type = match[2]
              @incoming = match[3].scan(/\[\s*(.+?)\s*,\s+%([-A-Za-z$._0-9]+)\s*\]/).map do |value, label|
                [value, label]
              end.freeze
              return
            end

            if (match = text.match(/\A(#{NAME})\s*=\s*phi\s+i128\s+(.+)\z/))
              @destination = match[1]
              @bits = 128
              @value_type = "i128"
              @incoming = match[2].scan(/\[\s*(.+?)\s*,\s+%([-A-Za-z$._0-9]+)\s*\]/).map do |value, label|
                [value, label]
              end.freeze
              return
            end

            if (match = text.match(/\A(#{NAME})\s*=\s*phi\s+i(1|8|16|32|64)\s+(.+)\z/))
              @destination = match[1]
              @bits = match[2].to_i
              @value_type = "i#{match[2]}"
              @incoming = match[3].scan(/\[\s*(.+?)\s*,\s+%([-A-Za-z$._0-9]+)\s*\]/).map do |value, label|
                [value, label]
              end.freeze
              return
            end

            match = text.match(/\A(#{NAME})\s*=\s*phi\s+(?:ptr|.+?\*)\s+(.+)\z/)
            return unless match

            @destination = match[1]
            @value_type = "ptr"
            @incoming = match[2].scan(/\[\s*(.+?)\s*,\s+%([-A-Za-z$._0-9]+)\s*\]/).map do |value, label|
              [value, label]
            end.freeze
          end
        end

        class ReturnInstruction < Instruction
          attr_reader :return_type, :value

          def initialize(text)
            super
            match = text.match(/\Aret\s+(void|ptr|i(?:1|8|16|32|64|128)|<\d+\s+x\s+i(?:1|8|16|32|64)>)(?:\s+(.+))?\z/)
            return unless match

            @return_type = match[1]
            @value = match[2]
          end
        end

        def self.parse(source)
          new(source).parse
        end

        def initialize(source)
          @source = source
        end

        def parse
          block_order, blocks = parse_main_blocks
          internal_functions = parse_internal_functions
          validate_function!("main", block_order, blocks)
          internal_functions.each_value do |function|
            validate_function!("@#{function.fetch(:name)}", function.fetch(:block_order), function.fetch(:blocks))
          end

          {
            block_order:,
            blocks:,
            function_signatures: parse_function_signatures,
            target_datalayout: parse_target_datalayout,
            global_numeric_data: parse_global_numeric_data,
            global_numeric_mutability: parse_global_numeric_mutability,
            global_strings: parse_global_strings,
            internal_functions:,
            source:,
            source_line_numbers:,
            struct_packed_types: parse_struct_packed_types,
            struct_types: parse_struct_types
          }
        end

        private

        attr_reader :source

        def parse_main_blocks
          parse_function_blocks(extract_main_body)
        end

        def parse_internal_functions
          functions = {}
          lines = source.each_line.to_a
          index = 0

          while index < lines.length
            header = lines[index].strip
            match = header.match(/\Adefine\s+(?:#{ATTRIBUTE_TOKEN}\s+)*(#{RETURN_TYPE})\s+@([-A-Za-z$._0-9]+)\((.*?)\)(?:\s+[^{}]+)?\s*\{\z/)
            unless match
              index += 1
              next
            end

            return_type = match[1]
            name = match[2]
            body = []
            index += 1
            while index < lines.length && lines[index].strip != "}"
              body << lines[index]
              index += 1
            end

            unless name == "main"
              order, blocks = parse_function_blocks(body.join)
              parameter_declarations = parse_parameter_declarations(match[3], require_names: true, allow_pointer: true, allow_varargs: false)
              functions[name] = {
                allocations: {},
                blocks:,
                block_order: order,
                name:,
                param_types: parameter_declarations.map { |parameter| parameter.fetch(:type) },
                params: parameter_declarations.map { |parameter| parameter.fetch(:name) },
                return_type:
              }
            end
            index += 1
          end

          functions
        end

        def parse_global_strings
          source.each_line.each_with_object({}) do |line, strings|
            stripped = line.sub(/;.*/, "").strip
            match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\bconstant\s+\[(\d+)\s+x\s+i8\]\s+c"((?:[^"\\]|\\.)*)"(?:,\s+align\s+\d+)?(?:,\s+![A-Za-z0-9_.-]+\s+![A-Za-z0-9_.-]+)?\z/)
            next unless match

            bytes = decode_llvm_string(match[3])
            if bytes.length > match[2].to_i
              raise parse_error("global string #{match[1]} exceeds declared width", stripped)
            end

            strings[match[1]] = bytes
          end
        end

        def parse_target_datalayout
          source.each_line do |line|
            match = line.strip.match(/\Atarget\s+datalayout\s*=\s*"([^"]*)"\z/)
            return match[1] if match
          end

          nil
        end

        def parse_struct_types
          source.each_line.each_with_object({}) do |line, structs|
            stripped = line.sub(/;.*/, "").strip
            match = stripped.match(/\A(%[-A-Za-z$._0-9]+)\s*=\s*type\s+(?:<)?\{\s*(.*?)\s*\}(?:>)?\z/)
            next unless match

            structs[match[1]] = Instruction.split_arguments(match[2]).freeze
          end
        end

        def parse_struct_packed_types
          source.each_line.each_with_object({}) do |line, structs|
            stripped = line.sub(/;.*/, "").strip
            match = stripped.match(/\A(%[-A-Za-z$._0-9]+)\s*=\s*type\s+<\{\s*.*?\s*\}>\z/)
            structs[match[1]] = true if match
          end
        end

        def parse_global_numeric_data
          source.each_line.each_with_object({}) do |line, globals|
            stripped = line.sub(/;.*/, "").strip
            next if stripped.empty?
            next if stripped.start_with?("@llvm.global_ctors =") || stripped.start_with?("@llvm.global_dtors =")

            if (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(?:global|constant)\s+i(1|8|16|32|64|128)\s+(-?\d+|zeroinitializer)(?:,\s+align\s+\d+)?\z/))
              globals[match[1]] = integer_bytes(match[3], match[2].to_i)
            elsif (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(?:global|constant)\s+i(1|8|16|32|64)\s+ptrtoint\s*\(.+\)(?:,\s+align\s+\d+)?\z/))
              globals[match[1]] = Array.new(byte_width(match[2].to_i), 0)
            elsif (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(?:global|constant)\s+ptr\s+(.+?)(?:,\s+align\s+\d+)?\z/))
              globals[match[1]] = Array.new(pointer_size, 0)
            elsif (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(?:global|constant)\s+\[(\d+)\s+x\s+i(1|8|16|32|64)\]\s+(zeroinitializer|\[(.*)\])(?:,\s+align\s+\d+)?\z/))
              globals[match[1]] = global_integer_array_bytes(match, stripped)
            elsif (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(?:global|constant)\s+(.+?)\s+(\{.*\}|\[.*\]|<.*>|zeroinitializer)(?:,\s+align\s+\d+)?\z/))
              globals[match[1]] = aggregate_initializer_bytes(match[2], match[3], stripped)
            end
          end
        end

        def parse_global_numeric_mutability
          source.each_line.each_with_object({}) do |line, globals|
            stripped = line.sub(/;.*/, "").strip
            next if stripped.empty?
            next if stripped.start_with?("@llvm.global_ctors =") || stripped.start_with?("@llvm.global_dtors =")

            if (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(global|constant)\s+i(?:1|8|16|32|64|128)\s+(?:-?\d+|zeroinitializer)(?:,\s+align\s+\d+)?\z/))
              globals[match[1]] = match[2] == "global"
            elsif (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(global|constant)\s+i(?:1|8|16|32|64)\s+ptrtoint\s*\(.+\)(?:,\s+align\s+\d+)?\z/))
              globals[match[1]] = match[2] == "global"
            elsif (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(global|constant)\s+ptr\s+.+?(?:,\s+align\s+\d+)?\z/))
              globals[match[1]] = match[2] == "global"
            elsif (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(global|constant)\s+\[\d+\s+x\s+i(?:1|8|16|32|64)\]\s+(?:zeroinitializer|\[.*\])(?:,\s+align\s+\d+)?\z/))
              globals[match[1]] = match[2] == "global"
            elsif (match = stripped.match(/\A(@[-A-Za-z$._0-9]+)\s*=.*?\b(global|constant)\s+.+?\s+(?:\{.*\}|\[.*\]|<.*>|zeroinitializer)(?:,\s+align\s+\d+)?\z/))
              globals[match[1]] = match[2] == "global"
            end
          end
        end

        def aggregate_initializer_bytes(type, initializer, line)
          return Array.new(type_size(type), 0) if initializer == "zeroinitializer"

          values = initializer.strip
          if (values.start_with?("{") && values.end_with?("}")) || (values.start_with?("[") && values.end_with?("]")) || (values.start_with?("<") && values.end_with?(">"))
            values = values[1...-1]
          end
          elements = Instruction.split_arguments(values)
          fields = aggregate_fields(type)
          if elements.length != fields.length
            raise parse_error("aggregate initializer has #{elements.length} elements, expected #{fields.length}", line)
          end

          output = Array.new(type_size(type), 0)
          fields.zip(elements).each_with_index do |(field_type, element), index|
            element_type, element_value = split_typed_initializer(element, field_type)
            bytes = typed_initializer_bytes(element_type, element_value, line)
            offset = aggregate_field_offsets(type).fetch(index)
            bytes.each_with_index { |byte, byte_index| output[offset + byte_index] = byte }
          end
          output
        end

        def typed_initializer_bytes(type, value, line)
          if (match = type.match(/\Ai(1|8|16|32|64)\z/))
            return integer_bytes(value, match[1].to_i)
          end
          if (match = type.match(/\Ai128\z/))
            return integer_bytes(value, 128)
          end
          return Array.new(pointer_size, 0) if pointer_type?(type)
          return aggregate_initializer_bytes(type, value, line) if aggregate_type?(type)

          raise parse_error("unsupported aggregate initializer type: #{type}", line)
        end

        def aggregate_type?(type)
          type.strip.match?(/\A(?:%[-A-Za-z$._0-9]+|\[\d+\s+x\s+.+\]|<\d+\s+x\s+i(?:1|8|16|32|64)>|(?:<)?\{.*\}(?:>)?)\z/)
        end

        def aggregate_fields(type)
          stripped = type.strip
          if (match = stripped.match(/\A\[(\d+)\s+x\s+(.+)\]\z/))
            return Array.new(match[1].to_i, match[2])
          end
          if (match = stripped.match(/\A<(\d+)\s+x\s+(i(?:1|8|16|32|64))>\z/))
            return Array.new(match[1].to_i, match[2])
          end
          return parse_struct_types.fetch(stripped) if parse_struct_types.key?(stripped)
          if stripped.match?(/\A(?:<)?\{.*\}(?:>)?\z/)
            return Instruction.split_arguments(stripped.delete_prefix("<").delete_prefix("{").delete_suffix(">").delete_suffix("}"))
          end

          raise ParseError, "unsupported aggregate type: #{type}"
        end

        def aggregate_field_offsets(type)
          return struct_layout(type).fetch(:field_offsets) if struct_type?(type)

          offset = 0
          aggregate_fields(type).map do |field|
            current = offset
            offset += type_size(field)
            current
          end
        end

        def type_size(type)
          stripped = type.strip
          return byte_width(Regexp.last_match(1).to_i) if stripped.match(/\Ai(1|8|16|32|64|128)\z/)
          return pointer_size if pointer_type?(stripped)
          if stripped.match(/\A\[(\d+)\s+x\s+(.+)\]\z/)
            count = Regexp.last_match(1).to_i
            element = Regexp.last_match(2)
            return type_size(element) * count
          end
          if stripped.match(/\A<(\d+)\s+x\s+(i(?:1|8|16|32|64))>\z/)
            count = Regexp.last_match(1).to_i
            element = Regexp.last_match(2)
            return type_size(element) * count
          end
          return struct_layout(stripped).fetch(:size) if struct_type?(stripped)

          raise ParseError, "unsupported type: #{type}"
        end

        def type_align(type)
          stripped = type.strip
          return integer_align(Regexp.last_match(1).to_i) if stripped.match(/\Ai(1|8|16|32|64|128)\z/)
          return pointer_align if pointer_type?(stripped)
          return type_align(Regexp.last_match(2)) if stripped.match(/\A\[(\d+)\s+x\s+(.+)\]\z/)
          return type_align(Regexp.last_match(2)) if stripped.match(/\A<(\d+)\s+x\s+(.+)>\z/)
          return struct_layout(stripped).fetch(:align) if struct_type?(stripped)

          1
        end

        def struct_type?(type)
          stripped = type.strip
          parse_struct_types.key?(stripped) || stripped.match?(/\A(?:<)?\{.*\}(?:>)?\z/)
        end

        def struct_layout(type)
          @struct_layout_cache ||= {}
          key = type.strip
          return @struct_layout_cache.fetch(key) if @struct_layout_cache.key?(key)

          offset = 0
          align = 1
          field_offsets = []
          packed = packed_struct?(key)
          fields = aggregate_fields(key)
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

        def packed_struct?(type)
          stripped = type.strip
          stripped.start_with?("<{") || parse_struct_packed_types.fetch(stripped, false)
        end

        def align_to(value, alignment)
          return value if alignment <= 1

          ((value + alignment - 1) / alignment) * alignment
        end

        def pointer_size
          return 8 unless parse_target_datalayout

          match = parse_target_datalayout.match(/(?:\A|-)p(?::\d+)?:([0-9]+)/)
          match ? byte_width(match[1].to_i) : 8
        end

        def pointer_align
          return pointer_size unless parse_target_datalayout

          match = parse_target_datalayout.match(/(?:\A|-)p(?::\d+)?:\d+:([0-9]+)/)
          match ? byte_width(match[1].to_i) : pointer_size
        end

        def integer_align(bits)
          match = parse_target_datalayout&.match(/(?:\A|-)i#{bits}:([0-9]+)/)
          match ? byte_width(match[1].to_i) : byte_width(bits)
        end

        def split_typed_initializer(element, expected_type)
          stripped = element.strip
          expected = expected_type.strip
          if stripped.start_with?("#{expected} ")
            return [expected, stripped.delete_prefix("#{expected} ").strip]
          end

          match = stripped.match(/\A(.+?)\s+(.+)\z/)
          raise parse_error("unsupported aggregate element: #{element}", element) unless match

          [pointer_type?(match[1]) ? "ptr" : match[1], match[2]]
        end

        def global_integer_array_bytes(match, line)
          count = match[2].to_i
          bits = match[3].to_i
          if match[4] == "zeroinitializer"
            return Array.new(count * byte_width(bits), 0)
          end

          elements = Instruction.split_arguments(match[5])
          if elements.length != count
            raise parse_error("global array #{match[1]} has #{elements.length} elements, expected #{count}", line)
          end

          elements.flat_map do |element|
            element_match = element.match(/\Ai#{bits}\s+(-?\d+|zeroinitializer)\z/)
            unless element_match
              raise parse_error("unsupported global array element: #{element}", line)
            end

            integer_bytes(element_match[1], bits)
          end
        end

        def integer_bytes(raw_value, bits)
          value = raw_value == "zeroinitializer" ? 0 : raw_value.to_i
          unsigned_value = value & integer_mask(bits)
          Array.new(byte_width(bits)) do |offset|
            (unsigned_value >> (offset * 8)) & 255
          end
        end

        def integer_mask(bits)
          return 1 if bits == 1

          (1 << bits) - 1
        end

        def byte_width(bits)
          [(bits + 7) / 8, 1].max
        end

        def parse_function_signatures
          source.each_line.each_with_object({}) do |line, signatures|
            stripped = line.sub(/;.*/, "").strip
            next if stripped.empty?

            if (match = stripped.match(/\Adeclare\s+(?:#{ATTRIBUTE_TOKEN}\s+)*(#{RETURN_TYPE})\s+@([-A-Za-z$._0-9]+)\((.*?)\)(?:\s+#[0-9]+)?\z/))
              add_function_signature!(
                signatures,
                build_function_signature(match[2], match[1], match[3], defined: false),
                stripped
              )
            elsif (match = stripped.match(/\Adefine\s+(?:#{ATTRIBUTE_TOKEN}\s+)*(#{RETURN_TYPE})\s+@([-A-Za-z$._0-9]+)\((.*?)\)(?:\s+[^{}]+)?\s*\{\z/))
              add_function_signature!(
                signatures,
                build_function_signature(match[2], match[1], match[3], defined: true),
                stripped
              )
            end
          end
        end

        def build_function_signature(name, return_type, raw_parameters, defined:)
          parameters = parse_parameter_declarations(raw_parameters, require_names: false, allow_pointer: true, allow_varargs: true)
          varargs = parameters.any? { |parameter| parameter.fetch(:type) == "..." }
          fixed_parameters = parameters.reject { |parameter| parameter.fetch(:type) == "..." }
          {
            defined:,
            name:,
            parameter_types: fixed_parameters.map { |parameter| parameter.fetch(:type) },
            return_type:,
            varargs:
          }
        end

        def add_function_signature!(signatures, signature, line)
          existing = signatures[signature.fetch(:name)]
          if existing && !same_function_signature?(existing, signature)
            raise parse_error("conflicting function signature for @#{signature.fetch(:name)}", line)
          end

          if existing
            existing[:defined] ||= signature.fetch(:defined)
          else
            signatures[signature.fetch(:name)] = signature
          end
        end

        def same_function_signature?(left, right)
          left.fetch(:return_type) == right.fetch(:return_type) &&
            left.fetch(:parameter_types) == right.fetch(:parameter_types) &&
            left.fetch(:varargs) == right.fetch(:varargs)
        end

        def decode_llvm_string(raw)
          bytes = []
          index = 0

          while index < raw.length
            if raw[index] == "\\"
              escape = raw[(index + 1), 2]
              if escape&.match?(/\A[0-9A-Fa-f]{2}\z/)
                bytes << escape.to_i(16)
                index += 3
              else
                bytes << raw[(index + 1)].ord
                index += 2
              end
            else
              bytes << raw[index].ord
              index += 1
            end
          end

          bytes
        end

        def parse_function_blocks(body)
          order = ["entry"]
          parsed = { "entry" => [] }
          current = "entry"

          Normalizer.lines(body).each do |stripped|
            next if stripped.empty?

            if (match = stripped.match(/\A([-A-Za-z$._0-9]+):\z/))
              current = match[1]
              order << current unless parsed.key?(current)
              parsed[current] ||= []
            else
              parsed[current] << Instruction.build(stripped, source_line: source_line_numbers[stripped])
            end
          end

          [order, parsed]
        end

        def parse_parameters(raw)
          parse_parameter_declarations(raw, require_names: true, allow_pointer: false, allow_varargs: false).map do |parameter|
            parameter.fetch(:name)
          end
        end

        def parse_parameter_declarations(raw, require_names:, allow_pointer:, allow_varargs:)
          return [] if raw.strip.empty?

          raw.split(",").map do |parameter|
            stripped = parameter.strip
            if stripped == "..."
              raise ParseError, "unsupported function parameter: #{parameter}" unless allow_varargs

              next({ type: "...", name: nil })
            end

            type_pattern = allow_pointer ? /i(?:1|8|16|32|64|128)|<\d+\s+x\s+i(?:1|8|16|32|64)>|ptr(?:\s+addrspace\(\d+\))?|metadata|.+?\*/ : /i(?:1|8|16|32|64)/
            match = stripped.match(/\A(#{type_pattern})(?:\s+(.+))?\z/)
            raise ParseError, "unsupported function parameter: #{parameter}" unless match
            name = match[2]&.match(/#{NAME}/)&.[](0)
            if require_names && name.nil?
              raise ParseError, "unsupported function parameter: #{parameter}"
            end

            { type: pointer_type?(match[1]) ? "ptr" : match[1], name: }
          end
        end

        def pointer_type?(type)
          type == "ptr" || type.start_with?("ptr addrspace(") || type.end_with?("*")
        end

        def extract_main_body
          lines = source.each_line.to_a
          start = lines.index { |line| line.match?(/\A\s*define\s+(?:#{ATTRIBUTE_TOKEN}\s+)*(?:#{RETURN_TYPE})\s+@main\s*\(/) }
          raise ParseError, "missing define @main()" if start.nil?

          body = []
          lines[(start + 1)..].each do |line|
            return body.join if line.strip == "}"

            body << line
          end

          raise ParseError, "unterminated @main function"
        end

        def source_line_numbers
          source.each_line.with_index(1).each_with_object({}) do |(raw_line, line_number), output|
            normalized = Normalizer.instruction(raw_line.sub(/;.*/, "").strip)
            next if normalized.empty?

            output[normalized] ||= line_number
          end
        end

        def validate_function!(function_name, order, blocks)
          validate_referenced_labels!(function_name, blocks)
          validate_reachable_blocks!(function_name, order, blocks)
        end

        def validate_referenced_labels!(function_name, blocks)
          valid_labels = blocks.keys
          blocks.each do |label, lines|
            lines.each do |line|
              referenced_labels(line).each do |target|
                next if valid_labels.include?(target)

                raise parse_error("undefined label %#{target} in #{function_name} block %#{label}", line)
              end
            end
          end
        end

        def validate_reachable_blocks!(function_name, order, blocks)
          reachable = reachable_labels(blocks)
          order.each do |label|
            next if reachable.include?(label)

            raise parse_error("unreachable block %#{label} in #{function_name}", "#{label}:")
          end
        end

        def reachable_labels(blocks)
          reachable = []
          pending = ["entry"]

          until pending.empty?
            label = pending.shift
            next if reachable.include?(label)
            next unless blocks.key?(label)

            reachable << label
            outgoing_labels(blocks.fetch(label)).each do |target|
              pending << target unless reachable.include?(target)
            end
          end

          reachable
        end

        def outgoing_labels(lines)
          terminator = lines.reverse.find { |line| line.start_with?("br ") || line.start_with?("switch ") || line.start_with?("ret ") || line == "unreachable" }
          return [] if terminator.nil? || terminator.start_with?("ret ") || terminator == "unreachable"

          branch_labels(terminator) + switch_labels(terminator)
        end

        def referenced_labels(line)
          return phi_labels(line) if line.match?(/\A#{NAME}\s*=\s*phi\b/)
          return branch_labels(line) if line.start_with?("br ")
          return switch_labels(line) if line.start_with?("switch ")

          []
        end

        def phi_labels(line)
          line.scan(/\[\s*.+?\s*,\s+%([-A-Za-z$._0-9]+)\s*\]/).flatten
        end

        def branch_labels(line)
          if (match = line.match(/\Abr\s+label\s+%([-A-Za-z$._0-9]+)\z/))
            return [match[1]]
          end

          match = line.match(/\Abr\s+i1\s+.+?,\s+label\s+%([-A-Za-z$._0-9]+),\s+label\s+%([-A-Za-z$._0-9]+)\z/)
          match ? [match[1], match[2]] : []
        end

        def switch_labels(line)
          match = line.match(/\Aswitch\s+i(?:1|8|16|32|64)\s+.+?,\s+label\s+%([-A-Za-z$._0-9]+)\s+\[(.*)\]\z/)
          return [] unless match

          [match[1]] + match[2].scan(/label\s+%([-A-Za-z$._0-9]+)/).flatten
        end

        def parse_error(message, line)
          line_number = source_line_numbers.fetch(line.to_s, nil)
          prefix = line_number ? "line #{line_number}: " : ""
          ParseError.new("#{prefix}#{message}")
        end
      end
    end
  end
end
