# frozen_string_literal: true

require_relative "../llvm_subset"

module PFC
  module Frontend
    class LLVMSubset
      class Parser
        NAME = /%[-A-Za-z$._0-9]+/

        def self.parse(source)
          new(source).parse
        end

        def initialize(source)
          @source = source
        end

        def parse
          block_order, blocks = parse_main_blocks
          {
            block_order:,
            blocks:,
            internal_functions: parse_internal_functions,
            source:,
            source_line_numbers:
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
            match = header.match(/\Adefine\s+(?:[-\w]+\s+)*(i32|void)\s+@([-A-Za-z$._0-9]+)\((.*?)\)\s*\{\z/)
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
              functions[name] = {
                allocations: {},
                blocks:,
                block_order: order,
                name:,
                params: parse_parameters(match[3]),
                return_type:
              }
            end
            index += 1
          end

          functions
        end

        def parse_function_blocks(body)
          order = ["entry"]
          parsed = { "entry" => [] }
          current = "entry"

          normalized_lines(body).each do |stripped|
            next if stripped.empty?

            if (match = stripped.match(/\A([-A-Za-z$._0-9]+):\z/))
              current = match[1]
              order << current unless parsed.key?(current)
              parsed[current] ||= []
            else
              parsed[current] << stripped
            end
          end

          [order, parsed]
        end

        def parse_parameters(raw)
          return [] if raw.strip.empty?

          raw.split(",").map do |parameter|
            match = parameter.strip.match(/\Ai(?:1|8|16|32)\s+(#{NAME})\z/)
            raise ParseError, "unsupported function parameter: #{parameter}" unless match

            match[1]
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

        def extract_main_body
          lines = source.each_line.to_a
          start = lines.index { |line| line.match?(/\A\s*define\s+(?:[-\w]+\s+)*(?:i32|void)\s+@main\s*\(/) }
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
            normalized = raw_line.sub(/;.*/, "").strip.gsub(/\s+/, " ")
            next if normalized.empty?

            output[normalized] ||= line_number
          end
        end
      end
    end
  end
end
