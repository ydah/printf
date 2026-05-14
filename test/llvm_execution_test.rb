# frozen_string_literal: true

require_relative "test_helper"

class LLVMExecutionTest < Minitest::Test
  include PFCTestHelper

  def test_runs_static_printf_sample
    assert_equal "n=-7 u=42 c=A s=ok %\n", compile_llvm_and_run("samples/printf_format.ll")
  end

  def test_runs_i64_sample
    assert_equal "Y 4294967301 -5\n", compile_llvm_and_run("samples/i64_ops.ll")
  end

  def test_runs_byte_addressed_memory_program
    source = <<~LLVM
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %arr = alloca [2 x i32], align 4
        %second = getelementptr inbounds [2 x i32], ptr %arr, i64 0, i64 1
        store i32 16961, ptr %second, align 4
        %byte = getelementptr inbounds i8, ptr %arr, i64 5
        %ch = load i8, ptr %byte, align 1
        call i32 @putchar(i32 %ch)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_runs_memory_intrinsic_program
    source = <<~LLVM
      declare void @llvm.memset.p0.i64(ptr writeonly, i8, i64, i1 immarg)
      declare void @llvm.memcpy.p0.p0.i64(ptr writeonly, ptr readonly, i64, i1 immarg)
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %src = alloca [4 x i8], align 1
        %dst = alloca [4 x i8], align 1
        call void @llvm.memset.p0.i64(ptr %src, i8 65, i64 4, i1 false)
        %second = getelementptr inbounds [4 x i8], ptr %src, i64 0, i64 1
        store i8 66, ptr %second, align 1
        call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %src, i64 4, i1 false)
        %copied = getelementptr inbounds [4 x i8], ptr %dst, i64 0, i64 1
        %ch = load i8, ptr %copied, align 1
        call i32 @putchar(i32 %ch)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_runs_overlapping_memmove_program
    source = <<~LLVM
      declare void @llvm.memmove.p0.p0.i64(ptr writeonly, ptr readonly, i64, i1 immarg)
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %buffer = alloca [5 x i8], align 1
        %p0 = getelementptr inbounds [5 x i8], ptr %buffer, i64 0, i64 0
        %p1 = getelementptr inbounds [5 x i8], ptr %buffer, i64 0, i64 1
        %p2 = getelementptr inbounds [5 x i8], ptr %buffer, i64 0, i64 2
        %p3 = getelementptr inbounds [5 x i8], ptr %buffer, i64 0, i64 3
        %p4 = getelementptr inbounds [5 x i8], ptr %buffer, i64 0, i64 4
        store i8 65, ptr %p0, align 1
        store i8 66, ptr %p1, align 1
        store i8 67, ptr %p2, align 1
        store i8 68, ptr %p3, align 1
        call void @llvm.memmove.p0.p0.i64(ptr %p1, ptr %p0, i64 4, i1 false)
        %c1 = load i8, ptr %p1, align 1
        %c2 = load i8, ptr %p2, align 1
        %c3 = load i8, ptr %p3, align 1
        %c4 = load i8, ptr %p4, align 1
        call i32 @putchar(i32 %c1)
        call i32 @putchar(i32 %c2)
        call i32 @putchar(i32 %c3)
        call i32 @putchar(i32 %c4)
        ret i32 0
      }
    LLVM

    assert_equal "ABCD", compile_llvm_source_and_run(source)
  end

  def test_runs_global_integer_program
    source = <<~LLVM
      @.value = global i32 16961, align 4
      @.items = constant [2 x i32] [i32 65, i32 66], align 4
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %low = load i8, ptr @.value, align 1
        call i32 @putchar(i32 %low)
        %second = getelementptr inbounds [2 x i32], ptr @.items, i64 0, i64 1
        %ch = load i32, ptr %second, align 4
        call i32 @putchar(i32 %ch)
        ret i32 0
      }
    LLVM

    assert_equal "AB", compile_llvm_source_and_run(source)
  end

  def test_runs_signed_extension_program
    source = <<~LLVM
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %wide = sext i8 -1 to i64
        %cmp = icmp eq i64 %wide, 18446744073709551615
        %out = select i1 %cmp, i32 89, i32 78
        call i32 @putchar(i32 %out)
        ret i32 0
      }
    LLVM

    assert_equal "Y", compile_llvm_source_and_run(source)
  end

  def test_runs_phi_swap_program
    source = <<~LLVM
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        br label %swap
      swap:
        %a = phi i32 [ 65, %entry ], [ %b, %swap ]
        %b = phi i32 [ 66, %entry ], [ %a, %swap ]
        %done = phi i1 [ 0, %entry ], [ 1, %swap ]
        br i1 %done, label %exit, label %swap
      exit:
        call i32 @putchar(i32 %a)
        call i32 @putchar(i32 %b)
        ret i32 0
      }
    LLVM

    assert_equal "BA", compile_llvm_source_and_run(source)
  end
end
