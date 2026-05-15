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

  def test_freeze_numeric_intrinsics_and_value_attributes
    source = <<~LLVM
      declare i32 @putchar(i32)
      declare i32 @llvm.smax.i32(i32, i32)
      declare i32 @llvm.abs.i32(i32, i1)
      declare i32 @llvm.bswap.i32(i32)
      declare i32 @llvm.ctpop.i32(i32)
      declare i32 @llvm.ctlz.i32(i32, i1)
      declare i32 @llvm.cttz.i32(i32, i1)

      define noundef i32 @main() #0 {
      entry:
        %frozen = freeze i32 65
        %max = call noundef i32 @llvm.smax.i32(i32 noundef %frozen, i32 noundef 66), !range !0
        %abs = call i32 @llvm.abs.i32(i32 -66, i1 true), !tbaa !1
        %swap = call i32 @llvm.bswap.i32(i32 1107296256)
        %pop = call i32 @llvm.ctpop.i32(i32 7)
        %lz = call i32 @llvm.ctlz.i32(i32 1, i1 false)
        %tz = call i32 @llvm.cttz.i32(i32 8, i1 false)
        %same_abs = icmp eq i32 %max, %abs
        %same_swap = icmp eq i32 %swap, 66
        %same_pop = icmp eq i32 %pop, 3
        %same_lz = icmp eq i32 %lz, 31
        %same_tz = icmp eq i32 %tz, 3
        %ok0 = and i1 %same_abs, %same_swap
        %ok1 = and i1 %same_pop, %same_lz
        %ok2 = and i1 %ok0, %ok1
        %ok = and i1 %ok2, %same_tz
        %value = select i1 %ok, i32 %max, i32 78
        call i32 @putchar(i32 %value)
        ret i32 0
      }

      attributes #0 = { noinline nounwind optnone }
      !0 = !{i32 0, i32 100}
      !1 = !{!2, !2, i64 0}
      !2 = !{!"int", !3}
      !3 = !{!"omnipotent char"}
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_memcpy_inline_and_gep_flags
    source = <<~LLVM
      declare void @llvm.memcpy.inline.p0.p0.i64(ptr, ptr, i64, i1)
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %src = alloca [2 x i8], align 1
        %dst = alloca [2 x i8], align 1
        %src0 = getelementptr inbounds nuw [2 x i8], ptr %src, i64 0, i64 0
        %src1 = getelementptr nusw [2 x i8], ptr %src, i64 0, i64 1
        store i8 65, ptr %src0, align 1
        store i8 66, ptr %src1, align 1
        call void @llvm.memcpy.inline.p0.p0.i64(ptr %dst, ptr %src, i64 2, i1 false)
        %dst1 = getelementptr inbounds [2 x i8], ptr %dst, i64 0, i64 1
        %value = load i8, ptr %dst1, align 1
        %wide = zext i8 %value to i32
        call i32 @putchar(i32 %wide)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_addrspacecast_zero_and_constant_bitcast
    source = <<~LLVM
      @.cell = global i8 66, align 1
      @.ptr = global ptr bitcast (ptr @.cell to ptr), align 8

      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %loaded = load ptr, ptr @.ptr, align 8
        %casted = addrspacecast ptr %loaded to ptr
        %value = load i8, ptr %casted, align 1
        %wide = zext i8 %value to i32
        call i32 @putchar(i32 %wide)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_dense_switch_fixture
    source = <<~LLVM
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        switch i32 4, label %default [
          i32 0, label %default
          i32 1, label %default
          i32 2, label %default
          i32 3, label %default
          i32 4, label %hit
          i32 5, label %default
        ]
      hit:
        call i32 @putchar(i32 66)
        ret i32 0
      default:
        call i32 @putchar(i32 78)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_nested_aggregate_pointer_field_extract_insert
    source = <<~LLVM
      %struct.Inner = type { i8, ptr }
      %struct.Outer = type { i8, %struct.Inner }

      @.cell = global i8 66, align 1

      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %outer = alloca %struct.Outer, align 8
        %loaded = load %struct.Outer, ptr %outer, align 8
        %updated = insertvalue %struct.Outer %loaded, ptr nonnull @.cell, 1, 1
        store %struct.Outer %updated, ptr %outer, align 8
        %stored = load %struct.Outer, ptr %outer, align 8
        %ptr = extractvalue %struct.Outer %stored, 1, 1
        %value = load i8, ptr %ptr, align 1
        call i32 @putchar(i32 %value)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_padded_and_packed_struct_layout
    source = <<~LLVM
      target datalayout = "e-m:o-i64:64-n32:64-S128"

      %struct.Padded = type { i8, i32 }
      %struct.Packed = type <{ i8, i32 }>

      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %padded = alloca %struct.Padded, align 4
        %packed = alloca %struct.Packed, align 1
        %padded_field = getelementptr %struct.Padded, ptr %padded, i64 0, i32 1
        %packed_field = getelementptr %struct.Packed, ptr %packed, i64 0, i32 1
        store i32 66, ptr %padded_field, align 4
        store i32 66, ptr %packed_field, align 1
        %padded_byte1 = getelementptr i8, ptr %padded, i64 1
        %packed_byte1 = getelementptr i8, ptr %packed, i64 1
        %padding = load i8, ptr %padded_byte1, align 1
        %packed_value = load i8, ptr %packed_byte1, align 1
        %is_padding_zero = icmp eq i8 %padding, 0
        %value = select i1 %is_padding_zero, i8 %packed_value, i8 78
        %wide = zext i8 %value to i32
        call i32 @putchar(i32 %wide)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_global_pointer_relocations_constant_gep_ptrtoint_and_alias
    source = <<~LLVM
      @.arr = global [2 x i8] [i8 65, i8 66], align 1
      @.cell_alias = alias i8, ptr getelementptr ([2 x i8], ptr @.arr, i64 0, i64 1)
      @.ptr = global ptr @.cell_alias, align 8
      @.addr = global i64 ptrtoint (ptr @.cell_alias to i64), align 8

      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %encoded = load i64, ptr @.addr, align 8
        %from_int = inttoptr i64 %encoded to ptr
        %from_global = load ptr, ptr @.ptr, align 8
        %same = icmp eq ptr %from_int, %from_global
        %value = load i8, ptr %from_global, align 1
        %out = select i1 %same, i8 %value, i8 78
        %wide = zext i8 %out to i32
        call i32 @putchar(i32 %wide)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_integer_vector_extractelement_and_insertelement
    source = <<~LLVM
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %vec0 = insertelement <2 x i8> zeroinitializer, i8 65, i32 0
        %vec1 = insertelement <2 x i8> %vec0, i8 66, i32 1
        %slot = alloca <2 x i8>, align 1
        store <2 x i8> %vec1, ptr %slot, align 1
        %loaded = load <2 x i8>, ptr %slot, align 1
        %value = extractelement <2 x i8> %loaded, i32 1
        %wide = zext i8 %value to i32
        call i32 @putchar(i32 %wide)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_i128_load_store_and_trunc_to_low_bits
    source = <<~LLVM
      @wide = global i128 66, align 16

      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        %slot = alloca i128, align 16
        %loaded = load i128, ptr @wide, align 16
        store i128 %loaded, ptr %slot, align 16
        %again = load i128, ptr %slot, align 16
        %narrow = trunc i128 %again to i32
        call i32 @putchar(i32 %narrow)
        ret i32 0
      }
    LLVM

    assert_equal "B", compile_llvm_source_and_run(source)
  end

  def test_llvm_global_ctors_and_dtors_are_ignored
    source = <<~LLVM
      @llvm.global_ctors = appending global [1 x { i32, ptr, ptr }] [{ i32 65535, ptr @ctor, ptr null }]
      @llvm.global_dtors = appending global [1 x { i32, ptr, ptr }] [{ i32 65535, ptr @dtor, ptr null }]

      declare i32 @putchar(i32)

      define internal void @ctor() {
      entry:
        ret void
      }

      define internal void @dtor() {
      entry:
        ret void
      }

      define i32 @main() {
      entry:
        call i32 @putchar(i32 66)
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

  def test_clang_attrs_intrinsics_smoke_fixture
    assert_equal "B", compile_llvm_and_run("samples/clang_attrs_intrinsics_smoke.ll")
  end

  def test_clang_optimized_smoke_fixture
    assert_equal "B", compile_llvm_and_run("samples/clang/optimized_smoke.ll")
  end
end
