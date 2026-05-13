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

  def test_threaded_emitter_uses_vm_state_and_instruction_table
    source = PFC::Backend::ThreadedCEmitter.new.emit(PFC::Frontend::Brainfuck.parse("+[.-]"))

    assert_includes source, "static const PFInstruction pf_program[]"
    assert_includes source, "unsigned short ip = 0;"
    assert_includes source, "unsigned char opcode = 0;"
    assert_includes source, "pf_set_opcode(pf_sink, &opcode, instruction.opcode);"
    assert_includes source, "PF_OP_JZ"
    assert_includes source, "PF_OP_JNZ"
  end

  def test_threaded_emitter_can_use_strict_primitives
    source = PFC::Backend::ThreadedCEmitter.new(strict_printf: true).emit(PFC::Frontend::Brainfuck.parse("+>"))

    assert_includes source, "pf_add_cell_strict(pf_sink, &tape[dp], instruction.operand);"
    assert_includes source, "pf_move_ptr_strict(pf_sink, &dp, instruction.operand)"
  end

  def test_emits_transfer_cell_primitive
    program = PFC::IR::Program.new([PFC::IR::TransferCell.new([[1, 2]])])
    source = PFC::Backend::CEmitter.new.emit(program)

    assert_includes source, "pf_transfer_cell(pf_sink, tape, dp, 1, 2)"
    assert_includes source, "pf_clear_cell(pf_sink, &tape[dp]);"
  end

  def test_strict_emits_strict_transfer_cell_primitive
    program = PFC::IR::Program.new([PFC::IR::TransferCell.new([[1, 2]])])
    source = PFC::Backend::CEmitter.new(strict_printf: true).emit(program)

    assert_includes source, "pf_transfer_cell_strict(pf_sink, tape, dp, 1, 2)"
  end

  def test_emits_16_bit_cell_backend
    source = PFC::Backend::CEmitter.new(cell_bits: 16).emit(PFC::Frontend::Brainfuck.parse("+."))

    assert_includes source, "unsigned short tape[TAPE_SIZE]"
    assert_includes source, "pf_add_cell16(pf_sink, &tape[dp], 1);"
    assert_includes source, "pf_output_cell16(tape[dp])"
  end

  def test_emits_32_bit_cell_backend
    source = PFC::Backend::CEmitter.new(cell_bits: 32).emit(PFC::Frontend::Brainfuck.parse("+."))

    assert_includes source, "PFCell32 tape[TAPE_SIZE]"
    assert_includes source, "pf_add_cell32(pf_sink, &tape[dp], 1);"
    assert_includes source, "pf_output_cell32(tape[dp])"
  end
end
