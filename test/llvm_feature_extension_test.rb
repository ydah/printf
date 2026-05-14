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
end
