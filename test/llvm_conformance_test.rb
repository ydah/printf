# frozen_string_literal: true

require "json"
require_relative "test_helper"

class LLVMConformanceTest < Minitest::Test
  include PFCTestHelper

  FIXTURE_ROOT = File.expand_path("fixtures/llvm", __dir__)
  SNAPSHOT_ROOT = File.expand_path("fixtures/c_snapshots", __dir__)

  SUPPORTED_FIXTURES = {
    "aggregate_phi_fields.ll" => "B",
    "internal_array_abi.ll" => "B",
    "minimal_return.ll" => "",
    "i128_add_signed_cmp.ll" => "B",
    "i128_shift_phi.ll" => "B",
    "internal_aggregate_calls.ll" => "B",
    "internal_memory_aggregate.ll" => "B",
    "internal_memory_intrinsics.ll" => "B",
    "vector_add.ll" => "B",
    "vector_scalarized_ops.ll" => "B",
    "vector_literal.ll" => "B",
    "i128_high_bits.ll" => "B"
  }.freeze

  UNSUPPORTED_FIXTURES = {
    "addrspace.ll" => "unsupported non-zero address space cast",
    "atomic.ll" => "unsupported atomic operation",
    "blockaddress.ll" => "unsupported blockaddress constant expression",
    "exception_handling.ll" => "unsupported exception handling instruction",
    "external_global.ll" => "unsupported external global reference",
    "float_add.ll" => "unsupported floating-point type",
    "varargs.ll" => "unsupported varargs instruction",
    "vector_add.ll" => "unsupported vector shuffle instruction",
    "vector_shuffle.ll" => "unsupported vector shuffle instruction"
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

  def test_fix_suggestions_for_unsupported_constructs_are_concrete
    path = unsupported_path("vector_add.ll")
    out, err = capture_io do
      assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check", "--fix-suggestions", path]).run
    end

    assert_empty err
    assert_includes out, "fix: lower this construct"
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
    assert plan.fetch("operations").first.key?("estimated_risk")
    assert plan.fetch("operations").first.key?("replacement_strategy")
    assert plan.fetch("operations").first.key?("requires_runtime_support")
    assert plan.fetch("operations").first.key?("blocking")
  end

  def test_lowering_plan_includes_warning_advisories
    Dir.mktmpdir("pfc-warning-plan") do |dir|
      path = File.join(dir, "warn.ll")
      File.write(path, <<~LLVM)
        define i32 @main() {
        entry:
          %slot = alloca i32, align 4
          store volatile i32 0, ptr %slot, align 4
          ret i32 0
        }
      LLVM

      out, err = capture_io do
        assert_equal 0, PFC::CLI.new(["llvm-capabilities", "--check", "--emit-lowering-plan", path]).run
      end
      assert_empty err
      plan = JSON.parse(out)
      assert_empty plan.fetch("operations")
      assert_equal "warning", plan.fetch("advisories").first.fetch("severity")
    end
  end

  def test_check_result_schema_keys_are_stable
    path = unsupported_path("float_add.ll")
    out, err = capture_io do
      assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check", "--json", path]).run
    end
    assert_empty err
    result = JSON.parse(out)
    expected = JSON.parse(File.read(File.join(FIXTURE_ROOT, "schema", "check_result_keys.json")))
    assert_equal expected.fetch("root"), result.keys.sort
    assert_equal expected.fetch("summary"), result.fetch("summary").keys.sort
    assert_equal expected.fetch("diagnostic"), result.fetch("diagnostics").first.keys.sort
  end

  def test_public_check_result_schema_is_available
    schema = JSON.parse(File.read(File.expand_path("../docs/llvm-capabilities.schema.json", __dir__)))
    assert_equal "pfc llvm-capabilities check result", schema.fetch("title")
    assert_includes schema.fetch("required"), "policy"
    assert schema.fetch("$defs").key?("diagnostic")
  end

  def test_check_dir_can_emit_sarif
    out, err = capture_io do
      assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check-dir", "--format=sarif", File.join(FIXTURE_ROOT, "unsupported")]).run
    end

    assert_empty err
    sarif = JSON.parse(out)
    assert_equal "2.1.0", sarif.fetch("version")
    assert_equal "pfc llvm-capabilities", sarif.fetch("runs").first.fetch("tool").fetch("driver").fetch("name")
    assert sarif.fetch("runs").first.fetch("results").any? { |result| result.fetch("level") == "error" }
    rule = sarif.fetch("runs").first.fetch("tool").fetch("driver").fetch("rules").first
    assert_includes rule.fetch("properties").fetch("tags"), "llvm"
    assert rule.key?("helpUri")
    rule_ids = sarif.fetch("runs").first.fetch("tool").fetch("driver").fetch("rules").map { |entry| entry.fetch("id") }
    assert_includes rule_ids, "pfc.llvm.error.floating-point"
    assert_includes rule_ids, "pfc.llvm.error.vector"
  end

  def test_capability_data_mentions_representative_lowered_features
    out, err = capture_io do
      assert_equal 0, PFC::CLI.new(["llvm-capabilities", "--json"]).run
    end

    assert_empty err
    values = JSON.parse(out).fetch("values").join("\n")
    tolerance = JSON.parse(out).fetch("tolerance").join("\n")
    %w[add/sub shl/lshr/ashr signed/unsigned vector].each do |feature|
      assert_includes values, feature
    end
    assert_includes tolerance, "SARIF"
  end

  def test_check_dir_reports_nested_llvm_files
    out, err = capture_io do
      assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check-dir", File.join(FIXTURE_ROOT, "unsupported")]).run
    end

    assert_empty err
    assert_includes out, "unsupported:"
    assert_includes out, "summary:"
    assert_includes out, "float_add.ll"
  end

  def test_check_dir_json_summary_filters_and_fail_on_warning
    Dir.mktmpdir("pfc-check-dir") do |dir|
      File.write(File.join(dir, "warn.ll"), <<~LLVM)
        define i32 @main() {
        entry:
          %slot = alloca i32, align 4
          store volatile i32 0, ptr %slot, align 4
          %value = load volatile i32, ptr %slot, align 4
          ret i32 %value
        }
      LLVM
      File.write(File.join(dir, "skip.ll"), <<~LLVM)
        define i32 @main() {
        entry:
          %x = fadd float 1.0, 2.0
          ret i32 0
        }
      LLVM

      out, err = capture_io do
        assert_equal 0, PFC::CLI.new(["llvm-capabilities", "--check-dir", "--json", "--include=warn.ll", dir]).run
      end
      assert_empty err
      result = JSON.parse(out)
      assert result.fetch("supported")
      assert_equal 1, result.fetch("summary").fetch("files")
      assert_equal 2, result.fetch("summary").fetch("warnings")

      _out, err = capture_io do
        assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check-dir", "--json", "--include=warn.ll", "--fail-on-warning", dir]).run
      end
      assert_empty err

      out, err = capture_io do
        assert_equal 0, PFC::CLI.new(["llvm-capabilities", "--check", "--json", "--fail-on=none", File.join(dir, "skip.ll")]).run
      end
      assert_empty err
      assert_equal "none", JSON.parse(out).fetch("policy").fetch("fail_on")

      _out, err = capture_io do
        assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check-dir", "--json", "--include=warn.ll", "--fail-on=none", "--max-warnings=1", dir]).run
      end
      assert_empty err
    end
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

  def test_static_preflight_classifies_unsupported_feature_families
    cases = {
      "atomic.ll" => ["fence seq_cst", "unsupported atomic operation"],
      "eh.ll" => ["landingpad { ptr, i32 } cleanup", "unsupported exception handling instruction"],
      "shuffle.ll" => ["%x = shufflevector <2 x i32> <i32 1, i32 2>, <2 x i32> <i32 3, i32 4>, <2 x i32> <i32 0, i32 2>", "unsupported vector shuffle instruction"],
      "varargs.ll" => ["%x = va_arg ptr null, i32", "unsupported varargs instruction"]
    }
    Dir.mktmpdir("pfc-feature-families") do |dir|
      cases.each do |name, (line, expected)|
        path = File.join(dir, name)
        File.write(path, <<~LLVM)
          define i32 @main() {
          entry:
            #{line}
            ret i32 0
          }
        LLVM
        out, err = capture_io do
          assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check", "--json", path]).run
        end
        assert_empty err
        messages = JSON.parse(out).fetch("diagnostics").map { |entry| entry.fetch("message") }.join("\n")
        assert_includes messages, expected
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
