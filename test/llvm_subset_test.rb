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
    assert_equal ["id"], parsed.fetch(:internal_functions).keys
    assert_equal ["ret i32 %x"], parsed.fetch(:internal_functions).fetch("id").fetch(:blocks).fetch("entry")
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
    assert_includes generated, "pf_call_0_out = (unsigned int)(89);"
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
end
