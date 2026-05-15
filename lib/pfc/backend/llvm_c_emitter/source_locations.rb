# frozen_string_literal: true

module PFC
  module Backend
    class LLVMCEmitter
      module SourceLocations
        private

        def with_statement_context(line)
          yield
        rescue Frontend::LLVMSubset::ParseError => e
          raise e if e.message.start_with?("line ")

          line_number = source_line_number(line)
          prefix = line_number ? "line #{line_number}: " : ""
          raise Frontend::LLVMSubset::ParseError, "#{prefix}#{e.message}"
        end

        def source_line_number(line)
          return line.source_line if line.respond_to?(:source_line) && line.source_line

          @source_line_numbers.fetch(instruction_text(line), nil)
        end

        def instruction_text(instruction)
          instruction.respond_to?(:text) ? instruction.text : instruction.to_s
        end

        def instruction_kind(instruction)
          instruction.respond_to?(:kind) ? instruction.kind : nil
        end
      end
    end
  end
end
