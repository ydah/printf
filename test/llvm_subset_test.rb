# frozen_string_literal: true

require_relative "test_helper"

class LLVMSubsetTest < Minitest::Test
  def test_parses_constant_putchar_program
    program = PFC::Frontend::LLVMSubset.parse(File.read(File.expand_path("../samples/putchar.ll", __dir__)))

    assert_instance_of PFC::IR::Program, program
    assert program.instructions.any? { |instruction| instruction.is_a?(PFC::IR::OutputCell) }
  end

  def test_rejects_dynamic_conditional_branch
    source = <<~LLVM
      declare i32 @getchar()
      define i32 @main() {
      entry:
        %ch = call i32 @getchar()
        br i1 %ch, label %yes, label %no
      yes:
        ret i32 0
      no:
        ret i32 0
      }
    LLVM

    assert_raises(PFC::Frontend::LLVMSubset::ParseError) do
      PFC::Frontend::LLVMSubset.parse(source)
    end
  end

  def test_follows_constant_conditional_branch
    source = <<~LLVM
      declare i32 @putchar(i32)
      define i32 @main() {
      entry:
        %cmp = icmp eq i32 1, 1
        br i1 %cmp, label %yes, label %no
      yes:
        call i32 @putchar(i32 89)
        ret i32 0
      no:
        call i32 @putchar(i32 78)
        ret i32 0
      }
    LLVM

    program = PFC::Frontend::LLVMSubset.parse(source)

    assert_equal "Program(ClearCell, AddCell(89), OutputCell)", program.inspect
  end

  def test_accepts_common_clang_spelling
    source = <<~LLVM
      declare i32 @putchar(i32)
      define dso_local i32 @main() {
      entry:
        %slot = alloca i8, align 1
        store i8 65, ptr %slot, align 1
        %value = load i8, ptr %slot, align 1
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    program = PFC::Frontend::LLVMSubset.parse(source)

    assert program.instructions.any? { |instruction| instruction.is_a?(PFC::IR::OutputCell) }
  end

  def test_dumps_cfg_for_dynamic_programs
    source = File.read(File.expand_path("../samples/dynamic_branch.ll", __dir__))

    assert_includes PFC::Backend::LLVMCEmitter.new(source).dump_ir, "LLVMSubsetCFG(blocks: entry, yes, no, merge"
  end
end
