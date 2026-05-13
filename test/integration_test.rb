# frozen_string_literal: true

require_relative "test_helper"

class IntegrationTest < Minitest::Test
  include PFCTestHelper

  def test_outputs_byte_three
    assert_equal "\x03".b, compile_and_run("+++.")
  end

  def test_wraps_cell_values
    assert_equal "\x00".b, compile_and_run("-+.")
  end

  def test_runs_hello_world
    source = File.read(File.expand_path("../samples/hello.bf", __dir__))

    assert_equal "Hello World!\n", compile_and_run(source)
  end

  def test_runs_cat_until_zero_byte
    source = File.read(File.expand_path("../samples/cat.bf", __dir__))

    assert_equal "abc", compile_and_run(source, input: "abc\x00tail")
  end

  def test_runs_loop_add_sample
    assert_equal "\b".b, compile_and_run("+++++>+++<[->+<]>.")
  end

  def test_strict_printf_runs_hello_world
    source = File.read(File.expand_path("../samples/hello.bf", __dir__))

    assert_equal "Hello World!\n", compile_and_run(source, strict_printf: true)
  end

  def test_runs_16_bit_cell_program
    assert_equal ",".b, compile_and_run("#{"+" * 300}.", cell_bits: 16)
  end

  def test_threaded_backend_runs_hello_world
    source = File.read(File.expand_path("../samples/hello.bf", __dir__))

    assert_equal "Hello World!\n", compile_and_run(source, backend: :threaded)
  end

  def test_threaded_backend_runs_cat_until_zero_byte
    source = File.read(File.expand_path("../samples/cat.bf", __dir__))

    assert_equal "abc", compile_and_run(source, input: "abc\x00tail", backend: :threaded)
  end

  def test_threaded_backend_runs_strict_hello_world
    source = File.read(File.expand_path("../samples/hello.bf", __dir__))

    assert_equal "Hello World!\n", compile_and_run(source, backend: :threaded, strict_printf: true)
  end

  def test_threaded_backend_runs_16_bit_cell_program
    assert_equal ",".b, compile_and_run("#{"+" * 300}.", backend: :threaded, cell_bits: 16)
  end

  def test_runs_32_bit_cell_program
    assert_equal ",".b, compile_and_run("#{"+" * 300}.", cell_bits: 32)
  end

  def test_threaded_backend_runs_32_bit_cell_program
    assert_equal ",".b, compile_and_run("#{"+" * 300}.", backend: :threaded, cell_bits: 32)
  end

  def test_runs_llvm_constant_putchar_sample
    assert_equal "B", compile_llvm_and_run("samples/putchar.ll")
  end

  def test_runs_llvm_getchar_add_sample
    assert_equal "B", compile_llvm_and_run("samples/getchar_add.ll", input: "A")
  end

  def test_runs_llvm_dynamic_branch_sample
    assert_equal "Y", compile_llvm_and_run("samples/dynamic_branch.ll", input: "A")
    assert_equal "N", compile_llvm_and_run("samples/dynamic_branch.ll", input: "B")
  end

  def test_runs_llvm_loop_sample
    assert_equal "XXX", compile_llvm_and_run("samples/countdown.ll")
  end

  def test_runs_llvm_gep_array_sample
    assert_equal "AB", compile_llvm_and_run("samples/gep_array.ll")
  end

  def test_runs_llvm_ops_select_sample
    assert_equal "B", compile_llvm_and_run("samples/ops_select.ll")
  end

  def test_runs_llvm_switch_sample
    assert_equal "X", compile_llvm_and_run("samples/switch.ll", input: "A")
    assert_equal "Y", compile_llvm_and_run("samples/switch.ll", input: "B")
    assert_equal "Z", compile_llvm_and_run("samples/switch.ll", input: "C")
  end

  def test_runs_llvm_dynamic_gep_sample
    assert_equal "B", compile_llvm_and_run("samples/dynamic_gep.ll", input: "1")
  end

  def test_runs_llvm_i32_memory_sample
    assert_equal ",", compile_llvm_and_run("samples/i32_memory.ll")
  end

  def test_runs_llvm_internal_call_sample
    assert_equal "B", compile_llvm_and_run("samples/internal_call.ll")
  end

  def test_runs_llvm_internal_cfg_sample
    assert_equal "YN", compile_llvm_and_run("samples/internal_cfg.ll")
  end

  def test_runs_llvm_internal_memory_sample
    assert_equal "B", compile_llvm_and_run("samples/internal_memory.ll")
  end

  def test_runs_llvm_internal_nested_call_sample
    assert_equal "B", compile_llvm_and_run("samples/internal_nested_call.ll")
  end

  def test_runs_llvm_void_main_sample
    assert_equal "A", compile_llvm_and_run("samples/void_main.ll")
  end

  def test_runs_llvm_i16_array_sample
    assert_equal "AB", compile_llvm_and_run("samples/i16_array.ll")
  end

  def test_runs_llvm_global_string_puts_sample
    assert_equal "Hi!\n", compile_llvm_and_run("samples/string_puts.ll")
  end

  def test_runs_llvm_printf_format_sample
    assert_equal "n=-7 u=42 c=A s=ok %\n", compile_llvm_and_run("samples/printf_format.ll")
  end
end
