# frozen_string_literal: true

require_relative "test_helper"

class LLVMCompatibilityTest < Minitest::Test
  def test_pointer_phi_selects_runtime_pointer
    source = <<~LLVM
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %left = alloca i8
        %right = alloca i8
        store i8 65, ptr %left
        store i8 66, ptr %right
        br i1 true, label %choose_right, label %choose_left
      choose_right:
        br label %join
      choose_left:
        br label %join
      join:
        %selected = phi ptr [ %right, %choose_right ], [ %left, %choose_left ]
        %value = load i8, ptr %selected
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_assume_expect_and_debug_intrinsics_are_tolerated
    source = <<~LLVM
      declare void @llvm.assume(i1)
      declare i1 @llvm.expect.i1(i1, i1)
      declare void @llvm.dbg.value(metadata, metadata, metadata)
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        call void @llvm.dbg.value(metadata i32 0, metadata !1, metadata !DIExpression())
        %expected = call i1 @llvm.expect.i1(i1 true, i1 true)
        call void @llvm.assume(i1 %expected)
        %value = select i1 %expected, i32 66, i32 78
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_struct_alloca_and_gep
    source = <<~LLVM
      %struct.Pair = type { i8, i8 }

      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %pair = alloca %struct.Pair, align 1
        %second = getelementptr %struct.Pair, ptr %pair, i32 0, i32 1
        store i8 66, ptr %second, align 1
        %value = load i8, ptr %second, align 1
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_typed_pointer_syntax_and_constant_count_alloca
    source = <<~LLVM
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %buffer = alloca i8, i64 2, align 1
        %slot = getelementptr i8, i8* %buffer, i64 1
        %casted = bitcast i8* %slot to i8*
        store i8 66, i8* %casted, align 1
        %value = load i8, i8* %slot, align 1
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_clang_smoke_fixture
    assert_equal "B", compile_llvm_and_run("samples/clang_smoke.ll")
  end
end
