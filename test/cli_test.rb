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
    assert_includes out, "static printf"
  end

  def test_llvm_capabilities_json_lists_supported_subset
    out, err = capture_io do
      assert_equal 0, PFC::CLI.new(["llvm-capabilities", "--json"]).run
    end

    assert_empty err
    capabilities = JSON.parse(out)
    assert_includes capabilities.fetch("values").join("\n"), "bitcast ptr-to-ptr"
    assert_includes capabilities.fetch("libc").join("\n"), "%p"
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
