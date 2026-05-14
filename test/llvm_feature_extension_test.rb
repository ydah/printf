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

  def test_global_pointer_can_roundtrip_through_integer_casts
    source = <<~LLVM
      @.cell = global i8 65

      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %address = ptrtoint ptr @.cell to i64
        %pointer = inttoptr i64 %address to ptr
        store i8 66, ptr %pointer
        %value = load i8, ptr @.cell
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_constant_global_integer_pointer_roundtrip_keeps_readonly_tag
    source = <<~LLVM
      @.cell = constant i8 65

      define i32 @main() {
      entry:
        %address = ptrtoint ptr @.cell to i64
        %pointer = inttoptr i64 %address to ptr
        store i8 66, ptr %pointer
        ret i32 0
      }
    LLVM

    c_source = PFC::Backend::LLVMCEmitter.new(source).emit
    assert_includes c_source, "PF_LLVM_READONLY_POINTER_TAG"
    assert_includes c_source, "LLVM write to constant global through pointer"
  end

  def test_pointer_icmp_with_null
    source = <<~LLVM
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %pointer = inttoptr i64 0 to ptr
        %is_null = icmp eq ptr %pointer, null
        %ch = select i1 %is_null, i32 66, i32 78
        call i32 @putchar(i32 %ch)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_internal_function_accepts_pointer_argument_and_bitcast
    source = <<~LLVM
      declare i32 @putchar(i32)

      define void @write(ptr %target) {
      entry:
        store i8 66, ptr %target
        ret void
      }

      define i32 @main() {
      entry:
        %buffer = alloca [1 x i8]
        %slot = getelementptr [1 x i8], ptr %buffer, i32 0, i32 0
        %casted = bitcast ptr %slot to ptr
        call void @write(ptr %casted)
        %value = load i8, ptr %slot
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_select_can_choose_pointer_values
    source = <<~LLVM
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %left = alloca i8
        %right = alloca i8
        store i8 65, ptr %left
        store i8 66, ptr %right
        %selected = select i1 1, ptr %right, ptr %left
        %value = load i8, ptr %selected
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_printf_additional_integer_flags_and_short_lengths
    source = <<~LLVM
      @.fmt = private unnamed_addr constant [30 x i8] c"a=%+05d b=%#06x c=%#o e=%hhd\\0A\\00"

      declare i32 @printf(ptr, ...)

      define i32 @main() {
      entry:
        call i32 (ptr, ...) @printf(ptr @.fmt, i32 -7, i32 26, i32 9, i32 255)
        ret i32 0
      }
    LLVM

    assert_equal "a=-0007 b=0x001a c=011 e=-1\n", compile_llvm_source_and_run(source)
  end

  def test_printf_dynamic_width_and_precision_for_static_strings
    source = <<~LLVM
      @.fmt = private unnamed_addr constant [9 x i8] c"[%*.*s]\\0A\\00"
      @.str = private unnamed_addr constant [7 x i8] c"abcdef\\00"

      declare i32 @printf(ptr, ...)

      define i32 @main() {
      entry:
        call i32 (ptr, ...) @printf(ptr @.fmt, i32 6, i32 3, ptr @.str)
        ret i32 0
      }
    LLVM

    assert_equal "[   abc]\n", compile_llvm_source_and_run(source)
  end

  def test_printf_pointer_format_outputs_encoded_pointer
    source = <<~LLVM
      @.fmt = private unnamed_addr constant [6 x i8] c"p=%p\\0A\\00"
      @.cell = global i8 65

      declare i32 @printf(ptr, ...)

      define i32 @main() {
      entry:
        call i32 (ptr, ...) @printf(ptr @.fmt, ptr @.cell)
        ret i32 0
      }
    LLVM

    assert_equal "p=0x8000000000000000\n", compile_llvm_source_and_run(source)
  end
end
