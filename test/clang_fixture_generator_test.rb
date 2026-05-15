# frozen_string_literal: true

require "minitest/autorun"
require_relative "../script/generate_clang_fixture"

class ClangFixtureGeneratorTest < Minitest::Test
  def test_normalize_fixture_for_check_ignores_environment_specific_llvm_output
    expected = normalize_fixture(<<~LLVM)
      ; ModuleID = 'sample.c'
      source_filename = "sample.c"
      target datalayout = "layout-a"
      target triple = "arm64-apple-macosx26.0.0"

      ; Function Attrs: nofree nounwind
      define range(i32 0, 2) i32 @main() #0 !dbg !12 {
          #dbg_value(i32 1, !15, !DIExpression(), !22)
        %1 = add i32 1, 2, !dbg !23
        %2 = call i32 @putchar(i32 %1), !dbg !24
        ret i32 %2, !dbg !25
      }

      attributes #0 = { nofree nounwind "target-cpu"="apple-m1" }

      !llvm.module.flags = !{!0}
      !0 = !{i32 2, !"SDK Version", [2 x i32] [i32 26, i32 4]}
      !11 = !{!"Apple clang version 21.0.0"}
    LLVM

    actual = normalize_fixture(<<~LLVM)
      ; ModuleID = 'sample.c'
      source_filename = "sample.c"
      target datalayout = "layout-b"
      target triple = "arm64-apple-macosx15.0.0"

      ; Function Attrs: mustprogress nofree nounwind
      define range(i32 0, 3) i32 @main() #3 !dbg !99 {
        call void @llvm.dbg.value(metadata i32 1, metadata !50, metadata !DIExpression()), !dbg !51
        %1 = add i32 1, 2, !dbg !52
        %2 = call i32 @putchar(i32 noundef %1), !dbg !53
        ret i32 %2, !dbg !54
      }

      declare void @llvm.dbg.value(metadata, metadata, metadata) #4
      declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #5
      attributes #3 = { mustprogress nofree nounwind "target-cpu"="apple-m4" }
      attributes #4 = { nounwind }

      !llvm.module.flags = !{!9}
      !9 = !{i32 2, !"SDK Version", [2 x i32] [i32 15, i32 4]}
      !20 = !{!"Apple clang version 18.0.0"}
    LLVM

    assert_equal expected, actual
  end

  def test_normalize_fixture_for_check_preserves_ir_instruction_changes
    expected = normalize_fixture("define i32 @main() {\n  ret i32 0\n}\n")
    actual = normalize_fixture("define i32 @main() {\n  ret i32 1\n}\n")

    refute_equal expected, actual
  end

  private

  def normalize_fixture(content)
    ClangFixtureGenerator.normalize_fixture_for_check(content)
  end
end
