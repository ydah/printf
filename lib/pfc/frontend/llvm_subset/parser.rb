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
          internal_functions = parse_internal_functions
          validate_function!("main", block_order, blocks)
          internal_functions.each_value do |function|
            validate_function!("@#{function.fetch(:name)}", function.fetch(:block_order), function.fetch(:blocks))
          end

          {
            block_order:,
            blocks:,
            internal_functions:,
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
          terminator = lines.reverse.find { |line| line.start_with?("br ") || line.start_with?("switch ") || line.start_with?("ret ") }
          return [] if terminator.nil? || terminator.start_with?("ret ")

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
          return [Regexp.last_match(1)] if line.match(/\Abr\s+label\s+%([-A-Za-z$._0-9]+)\z/)

          match = line.match(/\Abr\s+i1\s+.+?,\s+label\s+%([-A-Za-z$._0-9]+),\s+label\s+%([-A-Za-z$._0-9]+)\z/)
          match ? [match[1], match[2]] : []
        end

        def switch_labels(line)
          match = line.match(/\Aswitch\s+i(?:1|8|16|32)\s+.+?,\s+label\s+%([-A-Za-z$._0-9]+)\s+\[(.*)\]\z/)
          return [] unless match

          [match[1]] + match[2].scan(/label\s+%([-A-Za-z$._0-9]+)/).flatten
        end

        def parse_error(message, line)
          line_number = source_line_numbers.fetch(line, nil)
          prefix = line_number ? "line #{line_number}: " : ""
          ParseError.new("#{prefix}#{message}")
        end
      end
    end
  end
end
