# frozen_string_literal: true

require_relative "test_helper"

class CEmitterTest < Minitest::Test
  def test_emits_printf_write_primitives
    program = PFC::IR::Program.new([PFC::IR::AddCell.new(1)])
    source = PFC::Backend::CEmitter.new.emit(program)

    assert_includes source, "%1$.*2$d%3$hhn"
    assert_includes source, "pf_add_cell(pf_sink, &tape[dp], 1);"
    refute_includes source, "printf_s"
  end

  def test_emits_positional_arguments_for_pointer_writes
    source = PFC::Backend::CEmitter.new.emit(PFC::IR::Program.new([
      PFC::IR::MovePtr.new(1)
    ]))

    assert_includes source, "%1$.*2$d%3$hhn"
    assert_includes source, "%1$.*2$d%3$hn"
  end

  def test_rejects_tape_size_that_does_not_fit_unsigned_short_dp
    assert_raises(ArgumentError) do
      PFC::Backend::CEmitter.new(tape_size: 65_536)
    end
  end

  def test_strict_printf_emits_step_primitives
    source = PFC::Backend::CEmitter.new(strict_printf: true).emit(PFC::IR::Program.new([
      PFC::IR::AddCell.new(2),
      PFC::IR::MovePtr.new(1),
      PFC::IR::AddCell.new(-1)
    ]))

    assert_includes source, "pf_inc_cell(pf_sink, &tape[dp]);"
    assert_includes source, "pf_dec_cell(pf_sink, &tape[dp]);"
    assert_includes source, "pf_move_ptr_strict(pf_sink, &dp, 1)"
    refute_includes source, "pf_add_cell(pf_sink, &tape[dp], 2);"
  end
end
