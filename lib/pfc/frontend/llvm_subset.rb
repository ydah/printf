# frozen_string_literal: true

require_relative "../ir"

module PFC
  module Frontend
    class LLVMSubset
      class ParseError < StandardError; end

      Const = Struct.new(:value, keyword_init: true)
      Cell = Struct.new(:slot, :delta, keyword_init: true)

      NAME = /%[-A-Za-z$._0-9]+/
      VALUE = /-?\d+|%[-A-Za-z$._0-9]+/

      def self.parse(source)
        new(source).parse
      end

      def initialize(source)
        @blocks = parse_blocks(source)
        @instructions = []
        @registers = {}
        @slots = {}
        @known_cells = {}
        @cursor = 0
        @next_slot = 0
        @scratch_slot = nil
      end

      def parse
        execute_blocks
        move_to(0)
        IR::Program.new(@instructions)
      end

      private

      def parse_blocks(source)
        body = extract_main_body(source)
        blocks = { "entry" => [] }
        current = "entry"

        body.each_line do |line|
          stripped = line.sub(/;.*/, "").strip
          next if stripped.empty?

          if (match = stripped.match(/\A([-A-Za-z$._0-9]+):\z/))
            current = match[1]
            blocks[current] ||= []
          else
            blocks[current] << stripped
          end
        end

        blocks
      end

      def extract_main_body(source)
        lines = source.each_line.to_a
        start = lines.index { |line| line.match?(/\A\s*define\s+(?:[-\w]+\s+)*i32\s+@main\s*\(/) }
        raise ParseError, "missing define i32 @main()" if start.nil?

        body = []
        lines[(start + 1)..].each do |line|
          return body.join if line.strip == "}"

          body << line
        end

        raise ParseError, "unterminated @main function"
      end

      def execute_blocks
        label = "entry"
        steps = 0

        while label
          raise ParseError, "unknown label: #{label}" unless @blocks.key?(label)
          raise ParseError, "too many basic block transitions" if steps > 10_000

          label = execute_block(@blocks.fetch(label))
          steps += 1
        end
      end

      def execute_block(lines)
        lines.each do |line|
          next_label = execute_line(line)
          return next_label unless next_label == :continue
        end

        raise ParseError, "basic block is missing terminator"
      end

      def execute_line(line)
        return :continue if parse_alloca(line)
        return :continue if parse_store(line)
        return :continue if parse_load(line)
        return :continue if parse_binary(line)
        return :continue if parse_icmp(line)
        return :continue if parse_call(line)
        return parse_branch(line) if line.start_with?("br ")
        return nil if line.start_with?("ret ")

        raise ParseError, "unsupported LLVM instruction: #{line}"
      end

      def parse_alloca(line)
        match = line.match(/\A(#{NAME})\s*=\s*alloca\s+i(8|16|32)(?:,\s+align\s+\d+)?\z/)
        return false unless match

        slot_for(match[1])
        true
      end

      def parse_store(line)
        match = line.match(/\Astore\s+i(8|16|32)\s+(#{VALUE}),\s+(?:ptr|i(?:8|16|32)\*)\s+(#{NAME})(?:,\s+align\s+\d+)?\z/)
        return false unless match

        materialize_to_slot(value_for(match[2]), slot_for(match[3]))
        true
      end

      def parse_load(line)
        match = line.match(/\A(#{NAME})\s*=\s*load\s+i(8|16|32),\s+(?:ptr|i(?:8|16|32)\*)\s+(#{NAME})(?:,\s+align\s+\d+)?\z/)
        return false unless match

        slot = slot_for(match[3])
        known = @known_cells[slot]
        @registers[match[1]] = known.nil? ? load_dynamic_cell(slot) : Const.new(value: known)
        true
      end

      def parse_binary(line)
        match = line.match(/\A(#{NAME})\s*=\s*(add|sub)\s+i(8|16|32)\s+(#{VALUE}),\s+(#{VALUE})\z/)
        return false unless match

        @registers[match[1]] = binary_value(match[2], match[3].to_i, value_for(match[4]), value_for(match[5]))
        true
      end

      def parse_icmp(line)
        match = line.match(/\A(#{NAME})\s*=\s*icmp\s+(eq|ne)\s+i(8|16|32)\s+(#{VALUE}),\s+(#{VALUE})\z/)
        return false unless match

        left = value_for(match[4])
        right = value_for(match[5])
        raise ParseError, "dynamic icmp is not supported yet" unless left.is_a?(Const) && right.is_a?(Const)

        result = left.value == right.value
        result = !result if match[2] == "ne"
        @registers[match[1]] = Const.new(value: result ? 1 : 0)
        true
      end

      def parse_call(line)
        if (match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@getchar\(\)\z/))
          slot = allocate_slot
          move_to(slot)
          @instructions << IR::InputCell.new
          @known_cells[slot] = nil
          @registers[match[1]] = Cell.new(slot:, delta: 0) if match[1]
          return true
        end

        match = line.match(/\A(?:(#{NAME})\s*=\s*)?call\s+i32\s+@putchar\(i32\s+(#{VALUE})\)\z/)
        return false unless match

        emit_output_value(value_for(match[2]))
        @registers[match[1]] = Const.new(value: 0) if match[1]
        true
      end

      def parse_branch(line)
        if (match = line.match(/\Abr\s+label\s+%([-A-Za-z$._0-9]+)\z/))
          return match[1]
        end

        match = line.match(/\Abr\s+i1\s+(#{VALUE}),\s+label\s+%([-A-Za-z$._0-9]+),\s+label\s+%([-A-Za-z$._0-9]+)\z/)
        raise ParseError, "unsupported branch: #{line}" unless match

        condition = value_for(match[1])
        raise ParseError, "dynamic conditional branch is not supported yet" unless condition.is_a?(Const)

        condition.value.zero? ? match[3] : match[2]
      end

      def value_for(token)
        return Const.new(value: Integer(token)) if token.match?(/\A-?\d+\z/)

        @registers.fetch(token) { raise ParseError, "unknown value: #{token}" }
      end

      def slot_for(name)
        @slots.fetch(name) do
          slot = allocate_slot
          @slots[name] = slot
          @known_cells[slot] = 0
          slot
        end
      end

      def allocate_slot
        slot = @next_slot
        @next_slot += 1
        slot
      end

      def scratch_slot
        @scratch_slot ||= allocate_slot
      end

      def load_dynamic_cell(slot)
        temp = allocate_slot
        copy_cell(slot, temp)
        Cell.new(slot: temp, delta: 0)
      end

      def binary_value(operator, bits, left, right)
        if left.is_a?(Const) && right.is_a?(Const)
          value = operator == "add" ? left.value + right.value : left.value - right.value
          return Const.new(value: mask(value, bits))
        end

        return cell_plus_const(left, right.value, operator) if left.is_a?(Cell) && right.is_a?(Const)

        materialized_binary(operator, left, right)
      end

      def cell_plus_const(cell, value, operator)
        delta = operator == "add" ? value : -value
        Cell.new(slot: cell.slot, delta: cell.delta + delta)
      end

      def materialized_binary(operator, left, right)
        temp = allocate_slot
        materialize_to_slot(left, temp)
        apply_value_to_slot(right, temp, operator == "add" ? 1 : -1)
        Cell.new(slot: temp, delta: 0)
      end

      def materialize_to_slot(value, slot)
        case value
        when Const
          set_cell(slot, value.value)
        when Cell
          if value.slot == slot
            add_to_slot(slot, value.delta)
          else
            copy_cell(value.slot, slot)
            add_to_slot(slot, value.delta)
          end
        else
          raise ParseError, "cannot materialize value: #{value.inspect}"
        end
      end

      def apply_value_to_slot(value, slot, sign)
        case value
        when Const
          add_to_slot(slot, sign * value.value)
        when Cell
          apply_cell_to_slot(value.slot, slot, sign)
          add_to_slot(slot, sign * value.delta)
        end
      end

      def emit_output_value(value)
        case value
        when Const
          set_cell(scratch_slot, value.value)
          move_to(scratch_slot)
          @instructions << IR::OutputCell.new
        when Cell
          move_to(value.slot)
          add_to_current(value.delta)
          @instructions << IR::OutputCell.new
          add_to_current(-value.delta)
        end
      end

      def set_cell(slot, value)
        move_to(slot)
        @instructions << IR::ClearCell.new
        add_to_current(value)
        @known_cells[slot] = value % 256
      end

      def add_to_slot(slot, delta)
        move_to(slot)
        add_to_current(delta)
      end

      def add_to_current(delta)
        normalized = delta % 256
        return if normalized.zero?

        @instructions << IR::AddCell.new(normalized)
        known = @known_cells[@cursor]
        @known_cells[@cursor] = known.nil? ? nil : (known + normalized) % 256
      end

      def copy_cell(source, destination)
        apply_cell_to_slot(source, destination, 1, clear_destination: true)
      end

      def apply_cell_to_slot(source, destination, sign, clear_destination: false)
        temp = allocate_slot
        set_cell(destination, 0) if clear_destination
        set_cell(temp, 0)
        move_to(source)
        @instructions << IR::Loop.new([
          IR::AddCell.new(-1),
          IR::MovePtr.new(destination - source),
          IR::AddCell.new(sign),
          IR::MovePtr.new(temp - destination),
          IR::AddCell.new(1),
          IR::MovePtr.new(source - temp)
        ])
        @known_cells[source] = 0
        @known_cells[destination] = nil
        @known_cells[temp] = nil
        move_to(temp)
        @instructions << IR::Loop.new([
          IR::AddCell.new(-1),
          IR::MovePtr.new(source - temp),
          IR::AddCell.new(1),
          IR::MovePtr.new(temp - source)
        ])
        @known_cells[source] = nil
        @known_cells[temp] = 0
      end

      def move_to(slot)
        delta = slot - @cursor
        return if delta.zero?

        @instructions << IR::MovePtr.new(delta)
        @cursor = slot
      end

      def mask(value, bits)
        value & ((1 << bits) - 1)
      end
    end
  end
end
