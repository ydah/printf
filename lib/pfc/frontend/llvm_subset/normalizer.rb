# frozen_string_literal: true

module PFC
  module Frontend
    class LLVMSubset
      class Normalizer
        NAME = /%[-A-Za-z$._0-9]+/
        INTEGER_TYPE = /i(?:1|8|16|32|64)/
        RETURN_TYPE = /(?:#{INTEGER_TYPE}|ptr|void)/
        ATTRIBUTE_TOKEN = /[-\w]+(?:\([^)]*\))?/

        def self.lines(body)
          new(body).lines
        end

        def self.instruction(line)
          new("").normalize_instruction_line(line)
        end

        def initialize(body)
          @body = body
        end

        def lines
          source_lines = @body.each_line.map { |line| line.sub(/;.*/, "").strip }
          output = []
          index = 0

          while index < source_lines.length
            line = source_lines[index]
            if line.start_with?("switch ") && line.include?("[") && !line.include?("]")
              line = collect_switch_line(line, source_lines, index + 1)
              index += 1 until index >= source_lines.length || source_lines[index].include?("]")
            end
            output << normalize_instruction_line(line)
            index += 1
          end

          output
        end

        def normalize_instruction_line(line)
          normalized = line.to_s.gsub(/\s+/, " ")
          normalized = normalized.sub(/\A(#{NAME}\s*=\s*)?(?:tail|musttail|notail)\s+call\b/, '\1call')
          normalized = normalized.sub(/\A(#{NAME}\s*=\s*)?call\s+(?:#{ATTRIBUTE_TOKEN}\s+)*(#{RETURN_TYPE})\b/, '\1call \2')
          normalized = normalized.sub(/\A(#{NAME}\s*=\s*)?load\s+volatile\s+/, '\1load ')
          normalized = normalized.sub(/\Astore\s+volatile\s+/, "store ")
          normalized = normalized.sub(/\s+#\d+\z/, "")
          loop do
            stripped = normalized.sub(/,\s*![A-Za-z0-9_.-]+(?:\s+![A-Za-z0-9_.-]+|\s+\{[^}]*\})?\z/, "")
            break if stripped == normalized

            normalized = stripped
          end
          normalized.sub(/\s+#\d+\z/, "")
        end

        private

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
      end
    end
  end
end
