# frozen_string_literal: true

require_relative "test_helper"

class LLVMSubsetTest < Minitest::Test
  def test_parser_exposes_main_and_internal_function_blocks
    source = <<~LLVM
      define i32 @id(i32 %x) {
      entry:
        ret i32 %x
      }

      define i32 @main() {
      entry:
        %value = call i32 @id(i32 7)
        ret i32 %value
      }
    LLVM

    parsed = PFC::Frontend::LLVMSubset::Parser.parse(source)

    assert_equal ["entry"], parsed.fetch(:block_order)
    assert_equal ["%value = call i32 @id(i32 7)", "ret i32 %value"], parsed.fetch(:blocks).fetch("entry")
    call = parsed.fetch(:blocks).fetch("entry").first
    ret = parsed.fetch(:blocks).fetch("entry").last
    assert_instance_of PFC::Frontend::LLVMSubset::Parser::CallInstruction, call
    assert_equal :call, call.kind
    assert_equal "%value", call.destination
    assert_equal "i32", call.return_type
    assert_equal "id", call.function_name
    assert_equal ["i32 7"], call.arguments
    assert_instance_of PFC::Frontend::LLVMSubset::Parser::ReturnInstruction, ret
    assert_equal :return, ret.kind
    assert_equal "i32", ret.return_type
    assert_equal "%value", ret.value
    assert_equal ["id"], parsed.fetch(:internal_functions).keys
    assert_equal ["ret i32 %x"], parsed.fetch(:internal_functions).fetch("id").fetch(:blocks).fetch("entry")
    signature = parsed.fetch(:function_signatures).fetch("id")
    assert_equal "i32", signature.fetch(:return_type)
    assert_equal ["i32"], signature.fetch(:parameter_types)
    refute signature.fetch(:varargs)
  end

  def test_parser_decodes_global_string_constants
    source = <<~LLVM
      @.msg = private unnamed_addr constant [4 x i8] c"A\\0AB\\00", align 1

      define i32 @main() {
      entry:
        ret i32 0
      }
    LLVM

    parsed = PFC::Frontend::LLVMSubset::Parser.parse(source)

    assert_equal [65, 10, 66, 0], parsed.fetch(:global_strings).fetch("@.msg")
  end

  def test_parser_rejects_undefined_branch_label
    source = <<~LLVM
      define i32 @main() {
      entry:
        br label %missing
      }
    LLVM

    error = assert_raises(PFC::Frontend::LLVMSubset::ParseError) do
      PFC::Frontend::LLVMSubset::Parser.parse(source)
    end

    assert_equal "line 3: undefined label %missing in main block %entry", error.message
  end

  def test_parser_rejects_unreachable_block
    source = <<~LLVM
      define i32 @main() {
      entry:
        ret i32 0
      dead:
        ret i32 1
      }
    LLVM

    error = assert_raises(PFC::Frontend::LLVMSubset::ParseError) do
      PFC::Frontend::LLVMSubset::Parser.parse(source)
    end

    assert_equal "line 4: unreachable block %dead in main", error.message
  end

  def test_parser_rejects_unknown_phi_incoming_label
    source = <<~LLVM
      define i32 @main() {
      entry:
        br label %merge
      merge:
        %value = phi i32 [ 1, %missing ]
        ret i32 %value
      }
    LLVM

    error = assert_raises(PFC::Frontend::LLVMSubset::ParseError) do
      PFC::Frontend::LLVMSubset::Parser.parse(source)
    end

    assert_equal "line 5: undefined label %missing in main block %merge", error.message
  end

  def test_parser_exposes_structured_branch_and_phi_instructions
    source = <<~LLVM
      define i32 @main() {
      entry:
        br i1 1, label %yes, label %no
      yes:
        br label %merge
      no:
        br label %merge
      merge:
        %value = phi i32 [ 89, %yes ], [ 78, %no ]
        ret i32 %value
      }
    LLVM

    parsed = PFC::Frontend::LLVMSubset::Parser.parse(source)
    conditional_branch = parsed.fetch(:blocks).fetch("entry").first
    phi = parsed.fetch(:blocks).fetch("merge").first

    assert_instance_of PFC::Frontend::LLVMSubset::Parser::BranchInstruction, conditional_branch
    assert_equal :branch, conditional_branch.kind
    assert_equal "1", conditional_branch.condition
    assert_equal ["yes", "no"], conditional_branch.targets
    assert_instance_of PFC::Frontend::LLVMSubset::Parser::PhiInstruction, phi
    assert_equal :phi, phi.kind
    assert_equal "%value", phi.destination
    assert_equal 32, phi.bits
    assert_equal [["89", "yes"], ["78", "no"]], phi.incoming
  end

  def test_emits_constant_putchar_program
    source = PFC::Backend::LLVMCEmitter.new(File.read(File.expand_path("../samples/putchar.ll", __dir__))).emit

    assert_includes source, "pf_output_cell"
    assert_includes source, "pf_set_u32"
  end

  def test_emits_dynamic_conditional_branch
    source = <<~LLVM
      declare i32 @getchar()
      declare i32 @putchar(i32)
      define i32 @main() {
      entry:
        %ch = call i32 @getchar()
        br i1 %ch, label %yes, label %no
      yes:
        call i32 @putchar(i32 89)
        ret i32 0
      no:
        call i32 @putchar(i32 78)
        ret i32 0
      }
    LLVM

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "if ((pf_v_ch) != 0u)"
    assert_includes generated, "goto pf_block_yes;"
  end

  def test_emits_constant_conditional_branch
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

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "pf_v_cmp = ((1) == (1)) ? 1u : 0u;"
    assert_includes generated, "goto pf_block_yes;"
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

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "pf_output_cell"
  end

  def test_dumps_cfg_for_dynamic_programs
    source = File.read(File.expand_path("../samples/dynamic_branch.ll", __dir__))

    assert_includes PFC::Backend::LLVMCEmitter.new(source).dump_ir, "LLVMSubsetCFG(blocks: entry, yes, no, merge"
  end

  def test_dumps_detailed_cfg_for_dynamic_programs
    source = File.read(File.expand_path("../samples/dynamic_branch.ll", __dir__))
    dump = PFC::Backend::LLVMCEmitter.new(source).dump_cfg

    assert_includes dump, "LLVMSubsetCFG\nmain:\n"
    assert_includes dump, "  block entry:"
    assert_includes dump, "    inst: %ch = call i32 @getchar()"
    assert_includes dump, "  block merge:"
    assert_includes dump, "    phi: %out = phi i32 [ 89, %yes ], [ 78, %no ]"
  end

  def test_dumps_internal_function_cfg
    source = File.read(File.expand_path("../samples/internal_cfg.ll", __dir__))
    dump = PFC::Backend::LLVMCEmitter.new(source).dump_cfg

    assert_includes dump, "functions:"
    assert_includes dump, "  @choose(%x) -> i32"
    assert_includes dump, "    block entry:"
  end

  def test_inlines_internal_cfg_functions
    source = File.read(File.expand_path("../samples/internal_cfg.ll", __dir__))
    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "goto pf_call_0_block_entry;"
    assert_match(/pf_call_0_out = pf_phi_tmp_\d+;/, generated)
    assert_includes generated, "goto pf_call_0_return;"
  end

  def test_rejects_recursive_internal_calls
    source = <<~LLVM
      define i32 @loop() {
      entry:
        %value = call i32 @loop()
        ret i32 %value
      }

      define i32 @main() {
      entry:
        %value = call i32 @loop()
        ret i32 %value
      }
    LLVM

    error = assert_raises(PFC::Frontend::LLVMSubset::ParseError) do
      PFC::Backend::LLVMCEmitter.new(source).emit
    end
    assert_equal "line 3: recursive internal call is unsupported: @loop", error.message
  end

  def test_supports_i1_memory_and_comparison
    source = <<~LLVM
      define i32 @main() {
      entry:
        %flag = alloca i1, align 1
        store i1 1, ptr %flag, align 1
        %value = load i1, ptr %flag, align 1
        %cmp = icmp eq i1 %value, 1
        %out = select i1 %cmp, i32 89, i32 78
        call i32 @putchar(i32 %out)
        ret i32 0
      }
    LLVM

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "llvm_slots[pf_slot_index] & 1u"
    assert_includes generated, "pf_v_cmp = ((pf_v_value) == (1)) ? 1u : 0u;"
  end

  def test_supports_i64_memory_arithmetic_and_printf
    source = <<~LLVM
      @.fmt = private unnamed_addr constant [11 x i8] c"%llu %lld\\0A\\00", align 1
      declare i32 @putchar(i32)
      declare i32 @printf(ptr, ...)

      define i32 @main() {
      entry:
        %slot = alloca i64, align 8
        store i64 4294967301, ptr %slot, align 8
        %wide = load i64, ptr %slot, align 8
        %minus = sub i64 0, 5
        %cmp = icmp eq i64 %wide, 4294967301
        %out = select i1 %cmp, i32 89, i32 78
        call i32 @putchar(i32 %out)
        %printed = call i32 (ptr, ...) @printf(ptr @.fmt, i64 %wide, i64 %minus)
        ret i32 0
      }
    LLVM

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "unsigned long long llvm_slots[PF_LLVM_SLOT_COUNT] = {0};"
    assert_includes generated, "llvm_slots[pf_slot_index] = (unsigned long long)(4294967301 & 18446744073709551615ull);"
    assert_includes generated, "pf_v_wide = (unsigned long long)(llvm_slots[pf_slot_index] & 18446744073709551615ull);"
    assert_includes generated, "pf_v_cmp = ((pf_v_wide) == (4294967301)) ? 1u : 0u;"
    assert_includes generated, "pf_output_u64_decimal((unsigned long long)(pf_v_wide), &pf_printf_count_0)"
    assert_includes generated, "pf_output_i64_decimal((long long)(pf_v_minus), &pf_printf_count_0)"
  end

  def test_supports_signed_extension
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

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "? ((-1) | ~255u)"
    assert_includes generated, "& 18446744073709551615ull"
    assert_includes generated, "pf_v_cmp = ((pf_v_wide) == (18446744073709551615)) ? 1u : 0u;"
  end

  def test_emits_phi_assignments_through_temporaries
    source = <<~LLVM
      declare i32 @putchar(i32)

      define i32 @main() {
      entry:
        br label %loop
      loop:
        %a = phi i32 [ 65, %entry ], [ %b, %loop ]
        %b = phi i32 [ 66, %entry ], [ %a, %loop ]
        br i1 1, label %exit, label %loop
      exit:
        call i32 @putchar(i32 %a)
        ret i32 0
      }
    LLVM

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_match(
      /unsigned long long pf_phi_tmp_\d+ = \(unsigned int\)\(\(pf_v_b\) & 4294967295u\);\n\s+unsigned long long pf_phi_tmp_\d+ = \(unsigned int\)\(\(pf_v_a\) & 4294967295u\);\n\s+pf_v_a = pf_phi_tmp_\d+;\n\s+pf_v_b = pf_phi_tmp_\d+;/,
      generated
    )
  end

  def test_supports_void_internal_calls
    source = <<~LLVM
      define void @emit(i32 %ch) {
      entry:
        call i32 @putchar(i32 %ch)
        ret void
      }

      define i32 @main() {
      entry:
        call void @emit(i32 65)
        ret i32 0
      }
    LLVM

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "goto pf_call_0_block_entry;"
    assert_includes generated, "goto pf_call_0_return;"
    refute_includes generated, "pf_call_0_ignored_return"
  end

  def test_emits_puts_for_global_string
    source = <<~LLVM
      @.msg = private unnamed_addr constant [4 x i8] c"Hi!\\00", align 1
      declare i32 @puts(ptr)

      define i32 @main() {
      entry:
        %result = call i32 @puts(ptr @.msg)
        ret i32 0
      }
    LLVM

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "pf_output_cell((unsigned char)(72))"
    assert_includes generated, "pf_output_cell((unsigned char)(10))"
    assert_includes generated, "pf_v_result = 4u;"
  end

  def test_emits_printf_for_global_string_gep
    source = <<~LLVM
      @.msg = private unnamed_addr constant [4 x i8] c"OK\\0A\\00", align 1
      declare i32 @printf(ptr, ...)

      define i32 @main() {
      entry:
        %ptr = getelementptr inbounds [4 x i8], ptr @.msg, i64 0, i64 0
        %result = call i32 (ptr, ...) @printf(ptr %ptr)
        ret i32 0
      }
    LLVM

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "pf_output_counted_cell((unsigned char)(79), &pf_printf_count_0)"
    assert_includes generated, "pf_output_counted_cell((unsigned char)(75), &pf_printf_count_0)"
    assert_includes generated, "pf_output_counted_cell((unsigned char)(10), &pf_printf_count_0)"
    assert_includes generated, "pf_v_result = (unsigned int)(pf_printf_count_0);"
  end

  def test_emits_printf_for_static_variadic_arguments
    source = <<~LLVM
      @.fmt = private unnamed_addr constant [24 x i8] c"n=%d u=%u c=%c s=%s %%\\0A\\00", align 1
      @.word = private unnamed_addr constant [3 x i8] c"ok\\00", align 1
      declare i32 @printf(ptr, ...)

      define i32 @main() {
      entry:
        %result = call i32 (ptr, ...) @printf(ptr @.fmt, i32 -7, i32 42, i32 65, ptr @.word)
        ret i32 0
      }
    LLVM

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "pf_output_i32_decimal((int)(-7), &pf_printf_count_0)"
    assert_includes generated, "pf_output_u32_decimal((unsigned int)(42), &pf_printf_count_0)"
    assert_includes generated, "pf_output_counted_cell((unsigned char)(65), &pf_printf_count_0)"
    assert_includes generated, "pf_v_result = (unsigned int)(pf_printf_count_0);"
  end

  def test_emits_printf_for_long_length_modifiers
    source = <<~LLVM
      @.fmt = private unnamed_addr constant [8 x i8] c"%lu %ld\\00", align 1
      declare i32 @printf(ptr, ...)

      define i32 @main() {
      entry:
        %result = call i32 (ptr, ...) @printf(ptr @.fmt, i32 42, i32 -7)
        ret i32 0
      }
    LLVM

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "pf_output_u64_decimal((unsigned long long)(42), &pf_printf_count_0)"
    assert_includes generated, "pf_output_i64_decimal((long long)(-7), &pf_printf_count_0)"
  end

  def test_emits_printf_for_radix_formats
    source = <<~LLVM
      @.fmt = private unnamed_addr constant [17 x i8] c"%x %X %o %llx\\00", align 1
      declare i32 @printf(ptr, ...)

      define i32 @main() {
      entry:
        %result = call i32 (ptr, ...) @printf(ptr @.fmt, i32 48879, i32 48879, i32 511, i64 4294967301)
        ret i32 0
      }
    LLVM

    generated = PFC::Backend::LLVMCEmitter.new(source).emit

    assert_includes generated, "pf_output_u32_radix((unsigned int)(48879), 16u, \"0123456789abcdef\", &pf_printf_count_0)"
    assert_includes generated, "pf_output_u32_radix((unsigned int)(48879), 16u, \"0123456789ABCDEF\", &pf_printf_count_0)"
    assert_includes generated, "pf_output_u32_radix((unsigned int)(511), 8u, \"0123456789abcdef\", &pf_printf_count_0)"
    assert_includes generated, "pf_output_u64_radix((unsigned long long)(4294967301), 16u, \"0123456789abcdef\", &pf_printf_count_0)"
  end

  def test_reports_source_line_for_unsupported_llvm_instruction
    source = <<~LLVM
      define i32 @main() {
      entry:
        fence seq_cst
        ret i32 0
      }
    LLVM

    error = assert_raises(PFC::Frontend::LLVMSubset::ParseError) do
      PFC::Backend::LLVMCEmitter.new(source).emit
    end

    assert_equal "line 3: unsupported LLVM instruction: fence seq_cst", error.message
  end

  def test_rejects_wrong_call_argument_count
    source = <<~LLVM
      declare i32 @putchar(i32)
      define i32 @main() {
      entry:
        call i32 @putchar()
        ret i32 0
      }
    LLVM

    error = assert_raises(PFC::Frontend::LLVMSubset::ParseError) do
      PFC::Backend::LLVMCEmitter.new(source).emit
    end

    assert_equal "line 4: wrong argument count for @putchar: expected 1, got 0", error.message
  end

  def test_rejects_wrong_call_argument_type
    source = <<~LLVM
      declare i32 @putchar(i32)
      define i32 @main() {
      entry:
        call i32 @putchar(i64 65)
        ret i32 0
      }
    LLVM

    error = assert_raises(PFC::Frontend::LLVMSubset::ParseError) do
      PFC::Backend::LLVMCEmitter.new(source).emit
    end

    assert_equal "line 4: call argument 1 type mismatch for @putchar: expected i32, got i64", error.message
  end

  def test_rejects_unsupported_builtin_declaration
    source = <<~LLVM
      declare i64 @putchar(i32)
      define i32 @main() {
      entry:
        ret i32 0
      }
    LLVM

    error = assert_raises(PFC::Frontend::LLVMSubset::ParseError) do
      PFC::Backend::LLVMCEmitter.new(source).emit
    end

    assert_equal "unsupported declaration for @putchar: expected i32(i32)", error.message
  end
end
