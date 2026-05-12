# frozen_string_literal: true

require_relative "test_helper"

class OptimizerTest < Minitest::Test
  def test_merges_add_cell_runs
    program = PFC::IR::Program.new([
      PFC::IR::AddCell.new(4),
      PFC::IR::AddCell.new(-3)
    ])

    assert_equal(
      PFC::IR::Program.new([PFC::IR::AddCell.new(1)]),
      PFC::Optimizer.optimize(program)
    )
  end

  def test_merges_move_ptr_runs
    program = PFC::IR::Program.new([
      PFC::IR::MovePtr.new(3),
      PFC::IR::MovePtr.new(-1)
    ])

    assert_equal(
      PFC::IR::Program.new([PFC::IR::MovePtr.new(2)]),
      PFC::Optimizer.optimize(program)
    )
  end

  def test_optimizes_clear_loop
    program = PFC::Frontend::Brainfuck.parse("[-]")

    assert_equal(
      PFC::IR::Program.new([PFC::IR::ClearCell.new]),
      PFC::Optimizer.optimize(program)
    )
  end
end
