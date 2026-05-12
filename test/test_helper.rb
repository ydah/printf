# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

require_relative "../lib/pfc"

module PFCTestHelper
  def compile_and_run(program, input: "", optimize: true)
    Dir.mktmpdir("pfc-test") do |dir|
      c_path = File.join(dir, "test.c")
      exe_path = File.join(dir, "test")
      ir = PFC::Frontend::Brainfuck.parse(program)
      ir = PFC::Optimizer.optimize(ir) if optimize
      File.write(c_path, PFC::Backend::CEmitter.new.emit(ir))

      compile_out, compile_status = Open3.capture2e(
        "cc", "-std=c11", "-Wall", "-Wextra", "-O0", c_path, "-o", exe_path
      )
      assert compile_status.success?, compile_out

      stdout, stderr, status = Open3.capture3(exe_path, stdin_data: input)
      assert status.success?, stderr

      stdout
    end
  end
end
