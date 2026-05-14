# frozen_string_literal: true

require_relative "test_helper"

class LLVMCompatibilityTest < Minitest::Test
  include PFCTestHelper

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

  def test_internal_call_can_return_ptr
    source = <<~LLVM
      @.cell = global i8 66, align 1

      declare i32 @putchar(i32)

      define internal ptr @choose() {
      entry:
        ret ptr @.cell
      }

      define i32 @main() {
      entry:
        %p = call ptr @choose()
        %value = load i8, ptr %p, align 1
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_aggregate_load_store_extractvalue_and_insertvalue
    source = <<~LLVM
      %struct.Pair = type { i8, i8 }

      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %pair = alloca %struct.Pair, align 1
        %loaded = load %struct.Pair, ptr %pair, align 1
        %updated = insertvalue %struct.Pair %loaded, i8 66, 1
        store %struct.Pair %updated, ptr %pair, align 1
        %stored = load %struct.Pair, ptr %pair, align 1
        %value = extractvalue %struct.Pair %stored, 1
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_struct_global_initializer
    source = <<~LLVM
      %struct.Pair = type { i8, i8 }

      @.pair = global %struct.Pair { i8 65, i8 66 }, align 1

      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %second = getelementptr %struct.Pair, ptr @.pair, i64 0, i32 1
        %value = load i8, ptr %second, align 1
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_constant_expression_gep_pointer_argument
    source = <<~LLVM
      @.text = private unnamed_addr constant [2 x i8] c"B\\00", align 1

      declare i32 @putchar(i32)

      define internal i32 @read(ptr %p) {
      entry:
        %value = load i8, ptr %p, align 1
        %wide = zext i8 %value to i32
        ret i32 %wide
      }

      define i32 @main() {
      entry:
        %value = call i32 @read(ptr getelementptr inbounds ([2 x i8], ptr @.text, i64 0, i64 0))
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_clang_smoke_fixture
    assert_equal "B", compile_llvm_and_run("samples/clang_smoke.ll")
  end

  def test_clang_aggregate_smoke_fixture
    assert_equal "B", compile_llvm_and_run("samples/clang_aggregate_smoke.ll")
  end
end
