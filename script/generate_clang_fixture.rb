# frozen_string_literal: true

require "fileutils"
require "optparse"
require "tmpdir"

module ClangFixtureGenerator
  module_function

  def normalize_fixture_for_check(content)
    normalized_lines = []

    content.each_line do |line|
      next if fixture_check_ignored_line?(line)

      line = line.gsub(/, ![-A-Za-z0-9_.]+ !\d+/, "")
      line = line.gsub(/\s+![-A-Za-z0-9_.]+ !\d+/, "")
      line = line.gsub(/\s+#\d+(?=(?:\s*\{|,|\s*$))/, "")
      normalized_lines << line.rstrip
    end

    normalized_lines.join("\n").gsub(/\n{3,}/, "\n\n").strip.concat("\n")
  end

  def fixture_check_ignored_line?(line)
    stripped = line.strip
    stripped.empty? ||
      stripped.start_with?("; Function Attrs:") ||
      stripped.start_with?("#dbg_") ||
      line.start_with?("target datalayout = ") ||
      line.start_with?("target triple = ") ||
      line.start_with?("attributes #") ||
      line.start_with?("!llvm.") ||
      line.match?(/\A!\d+ = /) ||
      line.include?("llvm.dbg.")
  end

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

  def run(argv)
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

    parser.parse!(argv)

    input, output = argv
    abort parser.to_s unless input && output && argv.length == 2
    abort "missing input: #{input}" unless File.file?(input)

    if options.fetch(:check)
      abort "missing output: #{output}" unless File.file?(output)

      Dir.mktmpdir("pfc-clang-fixture") do |dir|
        generated = File.join(dir, File.basename(output))
        generate_fixture(options, input, generated)
        generated_content = normalize_fixture_for_check(File.binread(generated))
        fixture_content = normalize_fixture_for_check(File.binread(output))
        next if generated_content == fixture_content

        warn "fixture is stale: #{output}"
        warn "regenerate with: #{options.fetch(:clang)} -S -emit-llvm -O#{options.fetch(:opt)} -g #{input} -o #{output}"
        exit 1
      end
    else
      FileUtils.mkdir_p(File.dirname(output))
      generate_fixture(options, input, output)
    end
  end
end

ClangFixtureGenerator.run(ARGV) if $PROGRAM_NAME == __FILE__
