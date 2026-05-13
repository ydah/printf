# frozen_string_literal: true

require_relative "../ir"

module PFC
  module Frontend
    class Brainfuck
      class ParseError < StandardError; end

      def self.parse(source)
        new(source).parse
      end

      def initialize(source)
        @source = source
        @index = 0
        @line = 1
        @column = 1
      end

      def parse
        instructions = parse_block(until_bracket: false)
        IR::Program.new(instructions)
      end

      private

      attr_reader :source

      def parse_block(until_bracket:, opening_location: nil)
        instructions = []

        while @index < source.length
          location = [@line, @column]
          char = source[@index]
          @index += 1
          advance_position(char)

          case char
          when "+"
            instructions << IR::AddCell.new(1)
          when "-"
            instructions << IR::AddCell.new(-1)
          when ">"
            instructions << IR::MovePtr.new(1)
          when "<"
            instructions << IR::MovePtr.new(-1)
          when "."
            instructions << IR::OutputCell.new
          when ","
            instructions << IR::InputCell.new
          when "["
            instructions << IR::Loop.new(parse_block(until_bracket: true, opening_location: location))
          when "]"
            raise ParseError, "unmatched ']' at #{format_location(location)}" unless until_bracket

            return coalesce(instructions)
          end
        end

        raise ParseError, "unmatched '[' at #{format_location(opening_location)}" if until_bracket

        coalesce(instructions)
      end

      def advance_position(char)
        if char == "\n"
          @line += 1
          @column = 1
          return
        end

        @column += 1
      end

      def format_location(location)
        line, column = location
        "line #{line}, column #{column}"
      end

      def coalesce(instructions)
        instructions.each_with_object([]) do |instruction, output|
          previous = output.last

          case instruction
          when IR::AddCell
            merge_add_cell(output, previous, instruction)
          when IR::MovePtr
            merge_move_ptr(output, previous, instruction)
          else
            output << instruction
          end
        end
      end

      def merge_add_cell(output, previous, instruction)
        if previous.is_a?(IR::AddCell)
          output.pop
          delta = previous.delta + instruction.delta
          output << IR::AddCell.new(delta) unless delta.zero?
          return
        end

        output << instruction unless instruction.delta.zero?
      end

      def merge_move_ptr(output, previous, instruction)
        if previous.is_a?(IR::MovePtr)
          output.pop
          delta = previous.delta + instruction.delta
          output << IR::MovePtr.new(delta) unless delta.zero?
          return
        end

        output << instruction unless instruction.delta.zero?
      end
    end
  end
end
