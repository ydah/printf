# frozen_string_literal: true

require_relative "test_helper"

class LLVMFeatureExtensionTest < Minitest::Test
  def test_printf_width_and_precision_formats
    source = <<~LLVM
      @.fmt = private unnamed_addr constant [29 x i8] c"n=%05d x=%.4x s=%5.2s c=%3c\\0A\\00"
      @.str = private unnamed_addr constant [7 x i8] c"abcdef\\00"

      declare i32 @printf(ptr, ...)

      define i32 @main() {
      entry:
        call i32 (ptr, ...) @printf(ptr @.fmt, i32 -7, i32 26, ptr @.str, i32 65)
        ret i32 0
      }
    LLVM

    assert_equal "n=-0007 x=001a s=   ab c=  A\n", compile_llvm_source_and_run(source)
  end

  def test_mutable_global_integer_memory_can_be_updated
    source = <<~LLVM
      @.cell = global i8 65

      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        store i8 66, ptr @.cell
        %value = load i8, ptr @.cell
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_constant_global_integer_memory_rejects_store
    source = <<~LLVM
      @.cell = constant i8 65

      define i32 @main() {
      entry:
        store i8 66, ptr @.cell
        ret i32 0
      }
    LLVM

    error = assert_raises(PFC::Frontend::LLVMSubset::ParseError) do
      PFC::Backend::LLVMCEmitter.new(source).emit
    end
    assert_includes error.message, "cannot write to constant global: @.cell"
  end

  def test_local_pointer_can_roundtrip_through_integer_casts
    source = <<~LLVM
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %buffer = alloca [4 x i8]
        %slot = getelementptr [4 x i8], ptr %buffer, i32 0, i32 1
        %address = ptrtoint ptr %slot to i64
        %pointer = inttoptr i64 %address to ptr
        store i8 66, ptr %pointer
        %value = load i8, ptr %slot
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end
end
