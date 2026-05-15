# frozen_string_literal: true

require "json"
require_relative "test_helper"

class LLVMConformanceTest < Minitest::Test
  include PFCTestHelper

  FIXTURE_ROOT = File.expand_path("fixtures/llvm", __dir__)
  SNAPSHOT_ROOT = File.expand_path("fixtures/c_snapshots", __dir__)

  SUPPORTED_FIXTURES = {
    "minimal_return.ll" => "",
    "vector_add.ll" => "B",
    "vector_literal.ll" => "B",
    "i128_high_bits.ll" => "B"
  }.freeze

  UNSUPPORTED_FIXTURES = {
    "addrspace.ll" => "unsupported non-zero address space cast",
    "blockaddress.ll" => "unsupported blockaddress constant expression",
    "external_global.ll" => "unsupported external global reference",
    "float_add.ll" => "unsupported floating-point type",
    "vector_add.ll" => "unsupported LLVM instruction mul"
  }.freeze

  def test_supported_conformance_fixtures_compile_and_pass_preflight
    SUPPORTED_FIXTURES.each do |name, expected_output|
      path = supported_path(name)
      assert_equal expected_output, compile_llvm_and_run("test/fixtures/llvm/supported/#{name}")

      out, err = capture_io do
        assert_equal 0, PFC::CLI.new(["llvm-capabilities", "--check", path]).run
      end
      assert_empty err
      assert_includes out, "supported: #{path}"
    end
  end

  def test_unsupported_conformance_fixtures_match_golden_diagnostics
    UNSUPPORTED_FIXTURES.each do |name, expected|
      path = unsupported_path(name)
      source = File.read(path)
      error = assert_raises(PFC::Frontend::LLVMSubset::ParseError) do
        PFC::Backend::LLVMCEmitter.new(source).emit
      end
      assert_includes error.message, expected

      out, err = capture_io do
        assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check", "--json", path]).run
      end
      assert_empty err
      diagnostic = JSON.parse(out).fetch("errors").find { |entry| entry.fetch("message").include?(expected) }
      refute_nil diagnostic
    end
  end

  def test_fix_suggestions_for_vector_arithmetic_are_concrete
    path = unsupported_path("vector_add.ll")
    out, err = capture_io do
      assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check", "--fix-suggestions", path]).run
    end

    assert_empty err
    assert_includes out, "fix: replace vector arithmetic with extractelement per lane"
  end

  def test_lowering_plan_is_structured_json
    path = unsupported_path("float_add.ll")
    out, err = capture_io do
      assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check", "--emit-lowering-plan", path]).run
    end

    assert_empty err
    plan = JSON.parse(out)
    assert_equal 1, plan.fetch("schema_version")
    assert_equal "rewrite_float_to_integer", plan.fetch("operations").first.fetch("strategy")
    assert_includes plan.fetch("operations").first.fetch("steps").join("\n"), "fixed-point"
    assert plan.fetch("operations").first.key?("before_ir")
    assert plan.fetch("operations").first.key?("after_ir_example")
    assert plan.fetch("operations").first.key?("confidence")
    assert plan.fetch("operations").first.key?("blocking")
  end

  def test_check_dir_reports_nested_llvm_files
    out, err = capture_io do
      assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check-dir", File.join(FIXTURE_ROOT, "unsupported")]).run
    end

    assert_empty err
    assert_includes out, "unsupported:"
    assert_includes out, "float_add.ll"
  end

  def test_static_preflight_fuzz_reports_explicit_diagnostics
    unsupported_opcodes = %w[fence atomicrmw cmpxchg landingpad va_arg]
    unsupported_opcodes.each do |opcode|
      Dir.mktmpdir("pfc-fuzz") do |dir|
        path = File.join(dir, "#{opcode}.ll")
        File.write(path, <<~LLVM)
          define i32 @main() {
          entry:
            #{opcode} seq_cst
            ret i32 0
          }
        LLVM
        out, err = capture_io do
          assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check", "--json", path]).run
        end
        assert_empty err
        result = JSON.parse(out)
        refute result.fetch("supported")
        assert result.fetch("errors").all? { |entry| entry.fetch("message").include?("unsupported") }
      end
    end
  end

  def test_generated_c_snapshot_for_minimal_return_is_deterministic
    generated = PFC::Backend::LLVMCEmitter.new(File.read(supported_path("minimal_return.ll"))).emit
    snapshot = File.join(SNAPSHOT_ROOT, "minimal_return.c")
    File.write(snapshot, generated) if ENV["UPDATE_SNAPSHOTS"] == "1"
    expected = File.read(snapshot)
    assert_equal expected, generated
  end

  def test_vector_index_out_of_range_aborts_at_runtime
    source = <<~LLVM
      define i32 @main() {
      entry:
        %value = extractelement <2 x i8> <i8 65, i8 66>, i32 2
        ret i32 0
      }
    LLVM

    Dir.mktmpdir("pfc-vector-bounds") do |dir|
      c_path = File.join(dir, "test.c")
      exe_path = File.join(dir, "test")
      File.write(c_path, PFC::Backend::LLVMCEmitter.new(source).emit)
      compile_out, compile_status = Open3.capture2e("cc", "-std=c11", "-Wall", "-Wextra", "-O0", c_path, "-o", exe_path)
      assert compile_status.success?, compile_out

      _stdout, stderr, status = Open3.capture3(exe_path)
      refute status.success?
      assert_includes stderr, "LLVM vector index out of range"
    end
  end

  private

  def supported_path(name)
    File.join(FIXTURE_ROOT, "supported", name)
  end

  def unsupported_path(name)
    File.join(FIXTURE_ROOT, "unsupported", name)
  end
end
