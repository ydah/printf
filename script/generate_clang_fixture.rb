# frozen_string_literal: true

require "fileutils"
require "optparse"
require "tmpdir"

options = {
  check: false,
  clang: ENV.fetch("CLANG", "clang"),
  opt: "0"
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/generate_clang_fixture.rb [options] INPUT.c OUTPUT.ll"
  opts.on("--check", "verify OUTPUT.ll is up to date without overwriting it") { options[:check] = true }
  opts.on("--clang=PATH", "clang executable path") { |value| options[:clang] = value }
  opts.on("-OLEVEL", "--opt=LEVEL", "Optimization level, default 0") { |value| options[:opt] = value }
end

parser.parse!

input, output = ARGV
abort parser.to_s unless input && output && ARGV.length == 2
abort "missing input: #{input}" unless File.file?(input)

def generate_fixture(options, input, output)
  command = [
    options.fetch(:clang),
    "-S",
    "-emit-llvm",
    "-O#{options.fetch(:opt)}",
    "-g",
    input,
    "-o",
    output
  ]

  return if system(*command)

  status = $?.exitstatus || 1
  abort "clang fixture generation failed with exit status #{status}"
end

if options.fetch(:check)
  abort "missing output: #{output}" unless File.file?(output)

  Dir.mktmpdir("pfc-clang-fixture") do |dir|
    generated = File.join(dir, File.basename(output))
    generate_fixture(options, input, generated)
    next if File.binread(generated) == File.binread(output)

    warn "fixture is stale: #{output}"
    warn "regenerate with: #{options.fetch(:clang)} -S -emit-llvm -O#{options.fetch(:opt)} -g #{input} -o #{output}"
    exit 1
  end
else
  FileUtils.mkdir_p(File.dirname(output))
  generate_fixture(options, input, output)
end
