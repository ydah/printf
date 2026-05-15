# frozen_string_literal: true

require "fileutils"
require "json"
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
      line = normalize_llvm_value_attributes(line)
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
      line.include?("llvm.dbg.") ||
      stripped.start_with?("declare ") && stripped.include?("@llvm.")
  end

  def normalize_llvm_value_attributes(line)
    line
      .gsub(/\bnoundef\s+/, "")
      .gsub(/\brange\([^)]+\)\s+/, "")
      .gsub(/\b(?:nuw|nsw|nusw)\s+/, "")
      .gsub(/\b(?:noalias|nocapture|readonly|readnone|writeonly|immarg)\b\s*/, "")
      .gsub(/\bcaptures\([^)]*\)\s*/, "")
      .gsub(/\bptr\s+align\s+\d+\s+/, "ptr ")
      .gsub(/\s+,/, ",")
  end

  def fixture_difference_summary(expected, actual)
    expected_lines = expected.lines
    actual_lines = actual.lines
    max_length = [expected_lines.length, actual_lines.length].max
    index = (0...max_length).find { |line_index| expected_lines[line_index] != actual_lines[line_index] }
    return "normalized fixture contents differ" unless index

    expected_line = expected_lines[index] || "<missing>\n"
    actual_line = actual_lines[index] || "<missing>\n"
    "normalized fixture differs at line #{index + 1}:\n- #{expected_line}+ #{actual_line}"
  end

  def write_diagnostic_json(path, payload)
    return unless path

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(payload))
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
      diagnostic_json: nil,
      opt: "0"
    }

    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/generate_clang_fixture.rb [options] INPUT.c OUTPUT.ll"
      opts.on("--check", "verify OUTPUT.ll is up to date without overwriting it") { options[:check] = true }
      opts.on("--clang=PATH", "clang executable path") { |value| options[:clang] = value }
      opts.on("--diagnostic-json=PATH", "write stale-check diagnostics to PATH when --check fails") { |value| options[:diagnostic_json] = value }
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

        summary = fixture_difference_summary(fixture_content, generated_content)
        warn "fixture is stale: #{output}"
        warn summary
        warn "regenerate with: #{options.fetch(:clang)} -S -emit-llvm -O#{options.fetch(:opt)} -g #{input} -o #{output}"
        write_diagnostic_json(
          options[:diagnostic_json],
          {
            schema_version: 1,
            status: "stale",
            source: input,
            fixture: output,
            opt: options.fetch(:opt),
            clang: options.fetch(:clang),
            summary:
          }
        )
        exit 1
      end
    else
      FileUtils.mkdir_p(File.dirname(output))
      generate_fixture(options, input, output)
    end
  end
end

ClangFixtureGenerator.run(ARGV) if $PROGRAM_NAME == __FILE__
