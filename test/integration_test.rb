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

  def test_threaded_backend_runs_hello_world
    source = File.read(File.expand_path("../samples/hello.bf", __dir__))

    assert_equal "Hello World!\n", compile_and_run(source, backend: :threaded)
  end

  def test_threaded_backend_runs_cat_until_zero_byte
    source = File.read(File.expand_path("../samples/cat.bf", __dir__))

    assert_equal "abc", compile_and_run(source, input: "abc\x00tail", backend: :threaded)
  end
end
