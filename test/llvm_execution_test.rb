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
