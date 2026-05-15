# frozen_string_literal: true

require "json"
require_relative "test_helper"

class CLITest < Minitest::Test
  def test_rejects_backend_option_for_llvm_input
    with_llvm_source do |path|
      _out, err = capture_io do
        assert_equal 1, PFC::CLI.new(["dump-c", "--backend=printf-threaded", path]).run
      end

      assert_includes err, "LLVM input does not support --backend=printf-threaded"
    end
  end

  def test_rejects_cell_options_for_llvm_input
    with_llvm_source do |path|
      _out, err = capture_io do
        assert_equal 1, PFC::CLI.new(["dump-c", "--cell-bits=16", "--strict-printf", "--no-opt", path]).run
      end

      assert_includes err, "LLVM input does not support --cell-bits=16, --strict-printf, --no-opt"
    end
  end

  def test_allows_tape_size_for_llvm_input
    with_llvm_source do |path|
      out, err = capture_io do
        assert_equal 0, PFC::CLI.new(["dump-c", "--tape-size=16", path]).run
      end

      assert_empty err
      assert_includes out, "#define TAPE_SIZE 16"
    end
  end

  def test_dump_cfg_rejects_brainfuck_input
    Dir.mktmpdir("pfc-cli-test") do |dir|
      path = File.join(dir, "main.bf")
      File.write(path, "+.")
      _out, err = capture_io do
        assert_equal 1, PFC::CLI.new(["dump-cfg", path]).run
      end

      assert_includes err, "dump-cfg only supports LLVM inputs"
    end
  end

  def test_dump_cfg_prints_llvm_blocks
    with_llvm_source do |path|
      out, err = capture_io do
        assert_equal 0, PFC::CLI.new(["dump-cfg", path]).run
      end

      assert_empty err
      assert_includes out, "LLVMSubsetCFG\nmain:\n"
      assert_includes out, "  block entry:"
    end
  end

  def test_llvm_capabilities_lists_supported_subset
    out, err = capture_io do
      assert_equal 0, PFC::CLI.new(["llvm-capabilities"]).run
    end

    assert_empty err
    assert_includes out, "LLVM subset capabilities:"
    assert_includes out, "ptrtoint"
    assert_includes out, "extractvalue"
    assert_includes out, "llvm.smax"
    assert_includes out, "llvm.bswap"
    assert_includes out, "addrspacecast"
    assert_includes out, "freeze"
    assert_includes out, "target datalayout"
    assert_includes out, "static printf"
  end

  def test_llvm_capabilities_json_lists_supported_subset
    out, err = capture_io do
      assert_equal 0, PFC::CLI.new(["llvm-capabilities", "--json"]).run
    end

    assert_empty err
    capabilities = JSON.parse(out)
    assert capabilities.fetch("values").join("\n").include?("literals")
    assert_includes capabilities.fetch("memory").join("\n"), "global string byte memory"
    assert_includes capabilities.fetch("memory").join("\n"), "aggregate load/store"
    assert_includes capabilities.fetch("memory").join("\n"), "pointer fields"
    assert_includes capabilities.fetch("memory").join("\n"), "struct field getelementptr"
    assert_includes capabilities.fetch("values").join("\n"), "bitcast ptr-to-ptr"
    assert_includes capabilities.fetch("values").join("\n"), "insertvalue"
    assert_includes capabilities.fetch("values").join("\n"), "llvm.abs"
    assert_includes capabilities.fetch("values").join("\n"), "llvm.ctpop"
    assert_includes capabilities.fetch("values").join("\n"), "pointer phi"
    assert_includes capabilities.fetch("values").join("\n"), "aggregate byte equality"
    assert_includes capabilities.fetch("control").join("\n"), "pointer/void returns"
    assert_includes capabilities.fetch("control").join("\n"), "sret"
    assert_includes capabilities.fetch("tolerance").join("\n"), "metadata"
    assert_includes capabilities.fetch("tolerance").join("\n"), "info"
    assert_includes capabilities.fetch("tolerance").join("\n"), "datalayout"
    assert_includes capabilities.fetch("tolerance").join("\n"), "inbounds/nuw/nusw"
    assert_includes capabilities.fetch("tolerance").join("\n"), "external globals"
    assert_includes capabilities.fetch("tolerance").join("\n"), "llvm.expect"
    assert_includes capabilities.fetch("libc").join("\n"), "%p"
    assert_includes capabilities.fetch("libc").join("\n"), "memcmp"
  end

  def test_llvm_capabilities_check_reports_supported_file
    with_llvm_source do |path|
      out, err = capture_io do
        assert_equal 0, PFC::CLI.new(["llvm-capabilities", "--check", path]).run
      end

      assert_empty err
      assert_includes out, "supported: #{path}"
    end
  end

  def test_llvm_capabilities_check_json_reports_multiple_errors
    Dir.mktmpdir("pfc-cli-test") do |dir|
      path = File.join(dir, "bad.ll")
      File.write(path, <<~LLVM)
        define i32 @main() {
        entry:
          %x = fadd float 1.0, 2.0
          %y = add <vscale x 2 x i32> zeroinitializer, zeroinitializer
          ret i32 0
        }
      LLVM

      out, err = capture_io do
        assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--check", "--json", path]).run
      end

      assert_empty err
      result = JSON.parse(out)
      assert_equal 1, result.fetch("schema_version")
      refute result.fetch("supported")
      messages = result.fetch("errors").map { |error| error.fetch("message") }.join("\n")
      assert_includes messages, "unsupported floating-point type"
      assert_includes messages, "unsupported scalable vector type"

      first_error = result.fetch("errors").first
      assert_equal "error", first_error.fetch("severity")
      assert_equal %w[docs_url explanation fix_suggestions hint line line_text message minimal_repro_hint opcode severity suggestion], first_error.keys.sort
      assert_includes first_error.fetch("hint"), "Lower floating-point"
      assert_includes first_error.fetch("explanation"), "floating-point semantics"
      assert_includes first_error.fetch("fix_suggestions").join("\n"), "fixed-point"
      assert_includes first_error.fetch("suggestion"), "fixed-point"
      assert_includes first_error.fetch("docs_url"), "#llvm-ir-subset"
      assert_includes first_error.fetch("minimal_repro_hint"), "llvm-capabilities --check"
    end
  end

  def test_llvm_capabilities_explain_prints_guidance
    Dir.mktmpdir("pfc-cli-test") do |dir|
      path = File.join(dir, "bad.ll")
      File.write(path, <<~LLVM)
        define i32 @main() {
        entry:
          %x = fadd float 1.0, 2.0
          ret i32 0
        }
      LLVM

      out, err = capture_io do
        assert_equal 1, PFC::CLI.new(["llvm-capabilities", "--explain", path]).run
      end

      assert_empty err
      assert_includes out, "unsupported: #{path}"
      assert_includes out, "opcode: fadd"
      assert_includes out, "hint: Lower floating-point operations"
      assert_includes out, "explanation: The backend models integer operations"
      assert_includes out, "fix: rewrite floating-point work"
    end
  end

  private

  def with_llvm_source
    Dir.mktmpdir("pfc-cli-test") do |dir|
      path = File.join(dir, "main.ll")
      File.write(path, <<~LLVM)
        define i32 @main() {
        entry:
          ret i32 0
        }
      LLVM
      yield path
    end
  end
end
