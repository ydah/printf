# frozen_string_literal: true

require_relative "test_helper"

class FrontendTest < Minitest::Test
  def test_ignores_invalid_characters_and_coalesces_runs
    program = PFC::Frontend::Brainfuck.parse("++ noise + >><")

    assert_equal(
      PFC::IR::Program.new([
        PFC::IR::AddCell.new(3),
        PFC::IR::MovePtr.new(1)
      ]),
      program
    )
  end

  def test_parses_nested_loops
    program = PFC::Frontend::Brainfuck.parse("[+[->+<]]")

    assert_equal 1, program.instructions.length
    assert_instance_of PFC::IR::Loop, program.instructions.first
  end

  def test_rejects_unmatched_open_bracket
    error = assert_raises(PFC::Frontend::Brainfuck::ParseError) do
      PFC::Frontend::Brainfuck.parse("[+")
    end

    assert_equal "unmatched '[' at line 1, column 1", error.message
  end

  def test_rejects_unmatched_close_bracket
    error = assert_raises(PFC::Frontend::Brainfuck::ParseError) do
      PFC::Frontend::Brainfuck.parse("+\n]")
    end

    assert_equal "unmatched ']' at line 2, column 1", error.message
  end
end
