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

  def test_optimizes_transfer_loop
    program = PFC::Frontend::Brainfuck.parse("[->+>++<<]")

    assert_equal(
      PFC::IR::Program.new([PFC::IR::TransferCell.new([[1, 1], [2, 2]])]),
      PFC::Optimizer.optimize(program)
    )
  end

  def test_collapses_clear_then_add_into_set_cell
    program = PFC::IR::Program.new([
      PFC::IR::ClearCell.new,
      PFC::IR::AddCell.new(65)
    ])

    assert_equal(
      PFC::IR::Program.new([PFC::IR::SetCell.new(65)]),
      PFC::Optimizer.optimize(program)
    )
  end

  def test_drops_overwritten_cell_updates
    program = PFC::IR::Program.new([
      PFC::IR::AddCell.new(4),
      PFC::IR::SetCell.new(8),
      PFC::IR::ClearCell.new
    ])

    assert_equal(
      PFC::IR::Program.new([PFC::IR::ClearCell.new]),
      PFC::Optimizer.optimize(program)
    )
  end
end
