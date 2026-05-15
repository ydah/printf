# frozen_string_literal: true

require "optparse"

options = {
  clang: ENV.fetch("CLANG", "clang"),
  opt: "0"
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/generate_clang_fixture.rb [options] INPUT.c OUTPUT.ll"
  opts.on("--clang=PATH", "clang executable path") { |value| options[:clang] = value }
  opts.on("-OLEVEL", "--opt=LEVEL", "Optimization level, default 0") { |value| options[:opt] = value }
end

parser.parse!

input, output = ARGV
abort parser.to_s unless input && output && ARGV.length == 2
abort "missing input: #{input}" unless File.file?(input)

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

unless system(*command)
  status = $?.exitstatus || 1
  abort "clang fixture generation failed with exit status #{status}"
end
