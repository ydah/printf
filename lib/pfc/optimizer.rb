# frozen_string_literal: true

require_relative "ir"

module PFC
  class Optimizer
    def self.optimize(program)
      new.optimize(program)
    end

    def optimize(program)
      IR::Program.new(optimize_instructions(program.instructions))
    end

    private

    def optimize_instructions(instructions)
      coalesce(instructions.map { |instruction| optimize_instruction(instruction) })
    end

    def optimize_instruction(instruction)
      return optimize_loop(instruction) if instruction.is_a?(IR::Loop)

      instruction
    end

    def optimize_loop(loop)
      body = optimize_instructions(loop.body)
      return IR::ClearCell.new if clear_loop?(body)

      IR::Loop.new(body)
    end

    def clear_loop?(body)
      body.length == 1 &&
        body.first.is_a?(IR::AddCell) &&
        [1, -1].include?(body.first.delta)
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
