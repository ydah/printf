# frozen_string_literal: true

require "English"
require "fileutils"
require "json"
require "optparse"
require "tmpdir"

require_relative "backend/c_emitter"
require_relative "backend/llvm_c_emitter"
require_relative "backend/threaded_c_emitter"
require_relative "frontend/brainfuck"
require_relative "frontend/llvm_subset"
require_relative "optimizer"

module PFC
  class CLI
    SUPPORTED_BACKENDS = ["printf-c-scheduler", "printf-threaded"].freeze
    DEFAULT_BACKEND = "printf-c-scheduler"
    DEFAULT_CC = ENV.fetch("CC", "cc")

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      command = @argv.shift
      return usage("missing command") if command.nil?

      case command
      when "compile"
        compile_command
      when "build"
        build_command
      when "run"
        run_command
      when "dump-ir"
        dump_ir_command
      when "dump-cfg"
        dump_cfg_command
      when "dump-c"
        dump_c_command
      when "llvm-capabilities"
        llvm_capabilities_command
      when "-h", "--help", "help"
        puts help
        0
      else
        usage("unknown command: #{command}")
      end
    rescue Frontend::Brainfuck::ParseError, Frontend::LLVMSubset::ParseError, OptionParser::ParseError, ArgumentError => e
      warn "pfc: #{e.message}"
      1
    end

    private

    def compile_command
      options = parse_options
      source_path = require_input_path!
      validate_source_options!(source_path, options)
      c_source = compile_source(File.read(source_path), options, source_path:)

      if options[:output]
        File.write(options[:output], c_source)
      else
        puts c_source
      end

      0
    end

    def build_command
      options = parse_options
      source_path = require_input_path!
      validate_source_options!(source_path, options)
      output = options[:output] || default_executable_path(source_path)

      Dir.mktmpdir("pfc") do |dir|
        c_path = File.join(dir, "generated.c")
        File.write(c_path, compile_source(File.read(source_path), options, source_path:))
        return compile_c(c_path, output, cc: options[:cc], debug: options[:debug])
      end
    end

    def run_command
      options = parse_options
      source_path = require_input_path!
      validate_source_options!(source_path, options)

      Dir.mktmpdir("pfc") do |dir|
        c_path = File.join(dir, "generated.c")
        exe_path = File.join(dir, "generated")
        File.write(c_path, compile_source(File.read(source_path), options, source_path:))
        status = compile_c(c_path, exe_path, cc: options[:cc], debug: options[:debug])
        return status unless status.zero?

        system(exe_path)
        return $CHILD_STATUS.exitstatus || 1
      end
    end

    def dump_ir_command
      options = parse_options
      source_path = require_input_path!
      validate_source_options!(source_path, options)
      if llvm_source?(source_path)
        puts Backend::LLVMCEmitter.new(File.read(source_path), tape_size: options[:tape_size]).dump_ir
        return 0
      end

      puts compile_ir(File.read(source_path), options, source_path:).inspect
      0
    end

    def dump_cfg_command
      options = parse_options
      source_path = require_input_path!
      validate_source_options!(source_path, options)
      raise ArgumentError, "dump-cfg only supports LLVM inputs" unless llvm_source?(source_path)

      puts Backend::LLVMCEmitter.new(File.read(source_path), tape_size: options[:tape_size]).dump_cfg
      0
    end

    def dump_c_command
      options = parse_options
      source_path = require_input_path!
      validate_source_options!(source_path, options)
      puts compile_source(File.read(source_path), options, source_path:)
      0
    end

    def llvm_capabilities_command
      check = false
      check_dir = false
      emit_lowering_plan = false
      explain = false
      exclude_patterns = []
      fail_on_warning = false
      fix_suggestions = false
      format = nil
      include_patterns = []
      json = false
      while @argv.first&.start_with?("--")
        case @argv.first
        when "--check"
          check = true
        when "--check-dir"
          check = true
          check_dir = true
        when "--explain"
          check = true
          explain = true
        when "--fix-suggestions"
          check = true
          fix_suggestions = true
        when "--emit-lowering-plan"
          check = true
          emit_lowering_plan = true
        when "--fail-on-warning"
          check = true
          fail_on_warning = true
        when /\A--format=(json|sarif)\z/
          check = true
          format = Regexp.last_match(1)
        when /\A--include=(.+)\z/
          check = true
          include_patterns << Regexp.last_match(1)
        when /\A--exclude=(.+)\z/
          check = true
          exclude_patterns << Regexp.last_match(1)
        when "--json"
          json = true
        else
          break
        end
        @argv.shift
      end

      if check
        path = require_input_path!
        raise ArgumentError, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?
        raise ArgumentError, "--include/--exclude are only supported with --check-dir" if !check_dir && (!include_patterns.empty? || !exclude_patterns.empty?)
        if check_dir
          raise ArgumentError, "llvm-capabilities --check-dir requires a directory" unless File.directory?(path)
          result = llvm_check_directory_result(path, include_patterns:, exclude_patterns:, fail_on_warning:)
        else
          raise ArgumentError, "llvm-capabilities --check only supports LLVM inputs" unless llvm_source?(path)
          result = llvm_check_result(path, fail_on_warning:)
        end

        if format == "sarif"
          puts JSON.pretty_generate(llvm_sarif(result))
        elsif emit_lowering_plan
          puts JSON.pretty_generate(llvm_lowering_plan(result))
        elsif json || format == "json"
          puts JSON.pretty_generate(result)
        elsif result.fetch(:supported)
          puts "supported: #{path}"
          print_llvm_check_summary(result) if result.key?(:summary)
        elsif result.key?(:files)
          puts "unsupported: #{path}"
          print_llvm_check_summary(result)
          result.fetch(:files).reject { |file| file.fetch(:supported) }.each do |file|
            file.fetch(:errors).each do |error|
              location = error.fetch(:line) ? "#{file.fetch(:path)}:#{error.fetch(:line)}" : file.fetch(:path)
              puts "  #{location}: [#{error.fetch(:severity)}] #{error.fetch(:message)}"
            end
          end
        else
          puts "unsupported: #{path}"
          result.fetch(:errors).each do |error|
            location = error.fetch(:line) ? "#{path}:#{error.fetch(:line)}" : path
            puts "  #{location}: [#{error.fetch(:severity)}] #{error.fetch(:message)}"
            if explain
              puts "    opcode: #{error.fetch(:opcode) || 'unknown'}"
              puts "    hint: #{error.fetch(:hint)}"
              puts "    explanation: #{error.fetch(:explanation)}"
            end
            if fix_suggestions || explain
              error.fetch(:fix_suggestions).each do |suggestion|
                puts "    fix: #{suggestion}"
              end
            end
          end
        end
        return result.fetch(:supported) ? 0 : 1
      end

      raise ArgumentError, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?

      puts(json ? JSON.pretty_generate(llvm_capabilities_data) : llvm_capabilities)
      0
    end

    def llvm_check_result(path, fail_on_warning: false)
      source = File.read(path)
      diagnostics = llvm_static_check_errors(source)
      begin
        Backend::LLVMCEmitter.new(source).emit
      rescue Frontend::LLVMSubset::ParseError, ArgumentError => e
        line = e.message[/\Aline (\d+):/, 1]&.to_i
        line_text = line ? source.lines.fetch(line - 1, "").strip : nil
        diagnostics << llvm_check_diagnostic(line:, line_text:, message: e.message)
      end
      diagnostics = diagnostics.uniq { |diagnostic| [diagnostic.fetch(:line), diagnostic.fetch(:severity), diagnostic.fetch(:message)] }
      errors = diagnostics.select { |diagnostic| diagnostic.fetch(:severity) == "error" }
      warnings = diagnostics.select { |diagnostic| diagnostic.fetch(:severity) == "warning" }
      supported = errors.empty? && (!fail_on_warning || warnings.empty?)
      {
        schema_version: 1,
        path:,
        supported:,
        summary: llvm_check_summary([{ supported:, errors:, diagnostics: }]),
        diagnostics:,
        errors:
      }
    end

    def llvm_check_directory_result(path, include_patterns: [], exclude_patterns: [], fail_on_warning: false)
      files = Dir.glob(File.join(path, "**", "*.ll")).sort.filter_map do |file|
        relative = file.delete_prefix("#{path}/")
        next unless llvm_check_directory_file_included?(relative, include_patterns, exclude_patterns)

        llvm_check_result(file, fail_on_warning:)
      end
      summary = llvm_check_summary(files)
      supported = files.all? { |file| file.fetch(:supported) }
      { schema_version: 1, path:, supported:, summary:, files: }
    end

    def llvm_check_directory_file_included?(relative, include_patterns, exclude_patterns)
      included = include_patterns.empty? || include_patterns.any? { |pattern| File.fnmatch?(pattern, relative, File::FNM_PATHNAME) }
      excluded = exclude_patterns.any? { |pattern| File.fnmatch?(pattern, relative, File::FNM_PATHNAME) }
      included && !excluded
    end

    def llvm_check_summary(files)
      diagnostics = files.flat_map { |file| file.fetch(:diagnostics, []) }
      errors = files.flat_map { |file| file.fetch(:errors, []) }
      warnings = diagnostics.select { |diagnostic| diagnostic.fetch(:severity) == "warning" }
      {
        files: files.length,
        supported_files: files.count { |file| file.fetch(:supported, false) },
        unsupported_files: files.count { |file| !file.fetch(:supported, false) },
        diagnostics: diagnostics.length,
        errors: errors.length,
        warnings: warnings.length
      }
    end

    def print_llvm_check_summary(result)
      summary = result.fetch(:summary)
      puts "summary: files=#{summary.fetch(:files)} supported=#{summary.fetch(:supported_files)} unsupported=#{summary.fetch(:unsupported_files)} errors=#{summary.fetch(:errors)} warnings=#{summary.fetch(:warnings)}"
    end

    def llvm_lowering_plan(result)
      if result.key?(:files)
        return {
          schema_version: 1,
          path: result.fetch(:path),
          supported: result.fetch(:supported),
          summary: result.fetch(:summary),
          files: result.fetch(:files).map { |file| llvm_lowering_plan(file) }
        }
      end

      {
        schema_version: 1,
        path: result.fetch(:path),
        supported: result.fetch(:supported),
        advisories: result.fetch(:diagnostics, []).select { |diagnostic| diagnostic.fetch(:severity) == "warning" }.map.with_index(1) do |diagnostic, index|
          llvm_lowering_advisory(diagnostic, index)
        end,
        operations: result.fetch(:errors).map.with_index(1) do |error, index|
          {
            id: "lower_#{index}",
            line: error.fetch(:line),
            opcode: error.fetch(:opcode),
            line_text: error.fetch(:line_text),
            before_ir: error.fetch(:line_text),
            after_ir_example: llvm_after_ir_example(error),
            reason: error.fetch(:message),
            strategy: llvm_lowering_strategy(error),
            replacement_strategy: llvm_lowering_replacement_strategy(error),
            confidence: llvm_lowering_confidence(error),
            estimated_risk: llvm_lowering_estimated_risk(error),
            requires_runtime_support: llvm_lowering_requires_runtime_support(error),
            blocking: llvm_lowering_blocking(error),
            steps: error.fetch(:fix_suggestions)
          }
        end
      }
    end

    def llvm_lowering_advisory(diagnostic, index)
      {
        id: "advise_#{index}",
        severity: diagnostic.fetch(:severity),
        line: diagnostic.fetch(:line),
        opcode: diagnostic.fetch(:opcode),
        line_text: diagnostic.fetch(:line_text),
        reason: diagnostic.fetch(:message),
        hint: diagnostic.fetch(:hint),
        explanation: diagnostic.fetch(:explanation),
        steps: diagnostic.fetch(:fix_suggestions)
      }
    end

    def llvm_sarif(result)
      {
        version: "2.1.0",
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        runs: [
          {
            tool: {
              driver: {
                name: "pfc llvm-capabilities",
                informationUri: "https://github.com/ydah/printf",
                rules: llvm_sarif_rules(result)
              }
            },
            results: llvm_sarif_results(result)
          }
        ]
      }
    end

    def llvm_sarif_rules(result)
      llvm_sarif_diagnostics(result).map do |diagnostic|
        rule_id = llvm_sarif_rule_id(diagnostic)
        {
          id: rule_id,
          name: rule_id,
          helpUri: "https://github.com/ydah/printf#llvm-ir-subset",
          shortDescription: { text: diagnostic.fetch(:hint) },
          fullDescription: { text: diagnostic.fetch(:explanation) },
          properties: {
            tags: ["llvm", "pfc", llvm_diagnostic_category(diagnostic)]
          }
        }
      end.uniq { |rule| rule.fetch(:id) }
    end

    def llvm_sarif_results(result)
      llvm_sarif_diagnostics(result).map do |diagnostic|
        {
          ruleId: llvm_sarif_rule_id(diagnostic),
          level: diagnostic.fetch(:severity) == "warning" ? "warning" : "error",
          message: { text: diagnostic.fetch(:message) },
          locations: [
            {
              physicalLocation: {
                artifactLocation: { uri: diagnostic.fetch(:path) },
                region: { startLine: diagnostic.fetch(:line) || 1 }
              }
            }
          ]
        }
      end
    end

    def llvm_sarif_diagnostics(result)
      if result.key?(:files)
        return result.fetch(:files).flat_map { |file| llvm_sarif_diagnostics(file) }
      end

      result.fetch(:diagnostics, []).map do |diagnostic|
        diagnostic.merge(path: result.fetch(:path))
      end
    end

    def llvm_sarif_rule_id(diagnostic)
      opcode = diagnostic.fetch(:opcode) || "unknown"
      "pfc.llvm.#{diagnostic.fetch(:severity)}.#{opcode}"
    end

    def llvm_diagnostic_category(diagnostic)
      text = [diagnostic.fetch(:message), diagnostic.fetch(:line_text)].compact.join("\n")
      return "atomic" if text.include?("atomic")
      return "exception-handling" if text.include?("exception handling")
      return "vector" if text.include?("vector") || text.include?("shufflevector")
      return "floating-point" if text.include?("floating-point")
      return "varargs" if text.include?("varargs")
      return "address-space" if text.include?("address space")
      return "i128" if text.include?("i128")

      "unsupported"
    end

    def llvm_lowering_strategy(error)
      text = [error.fetch(:message), error.fetch(:line_text)].compact.join("\n")
      return "scalarize_vector_arithmetic" if text.match?(/\b(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)\s+<\d+\s+x\s+i(?:1|8|16|32|64)>/)
      return "rewrite_float_to_integer" if text.include?("floating-point")
      return "narrow_or_restrict_i128" if text.include?("i128")
      return "replace_blockaddress_control_flow" if text.include?("blockaddress")
      return "materialize_external_global" if text.include?("external global")
      return "lower_to_default_address_space" if text.include?("address space")

      "manual_lowering_required"
    end

    def llvm_lowering_replacement_strategy(error)
      text = [error.fetch(:message), error.fetch(:line_text)].compact.join("\n")
      return "lane_by_lane_scalar_ir" if text.include?("vector") || text.match?(/<\d+\s+x\s+i(?:1|8|16|32|64)>/)
      return "fixed_point_or_integer_domain_rewrite" if text.include?("floating-point")
      return "split_high_low_halves_or_narrow" if text.include?("i128")
      return "structured_branch_rewrite" if text.include?("blockaddress")
      return "explicit_storage_materialization" if text.include?("external global")
      return "target_independent_pointer_lowering" if text.include?("address space")

      "manual_ir_rewrite"
    end

    def llvm_after_ir_example(error)
      text = [error.fetch(:message), error.fetch(:line_text)].compact.join("\n")
      return "%lane = extractelement <N x iM> %vector, i32 0\n%sum = add iM %lane, %other_lane\n%next = insertelement <N x iM> %acc, iM %sum, i32 0" if text.match?(/\b(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)\s+<\d+\s+x\s+i(?:1|8|16|32|64)>/)
      return "%fixed = call i32 @fixed_point_lowered(...)" if text.include?("floating-point")
      return "%narrow = trunc i128 %wide to i64" if text.include?("i128")
      return "br label %target" if text.include?("blockaddress")

      nil
    end

    def llvm_lowering_confidence(error)
      text = [error.fetch(:message), error.fetch(:line_text)].compact.join("\n")
      return "high" if text.include?("floating-point") || text.include?("i128") || text.include?("vector") || text.match?(/<\d+\s+x\s+i(?:1|8|16|32|64)>/)
      return "medium" if text.include?("blockaddress") || text.include?("address space")

      "low"
    end

    def llvm_lowering_estimated_risk(error)
      text = [error.fetch(:message), error.fetch(:line_text)].compact.join("\n")
      return "high" if text.include?("floating-point") || text.include?("blockaddress") || text.include?("address space")
      return "medium" if text.include?("i128") || text.include?("external global")
      return "low" if text.include?("vector") || text.match?(/<\d+\s+x\s+i(?:1|8|16|32|64)>/)

      "medium"
    end

    def llvm_lowering_requires_runtime_support(error)
      text = [error.fetch(:message), error.fetch(:line_text)].compact.join("\n")
      text.include?("external global") || text.include?("address space") || text.include?("blockaddress")
    end

    def llvm_lowering_blocking(error)
      error.fetch(:severity) == "error"
    end

    def llvm_static_check_errors(source)
      source.each_line.with_index(1).filter_map do |raw_line, line_number|
        line = raw_line.sub(/;.*/, "").strip
        next if line.empty? || line == "}" || line.match?(/\A[-A-Za-z$._0-9]+:\z/)
        next if line.match?(/\A(?:source_filename|target|attributes|![A-Za-z0-9_.-]+|declare|define)\b/)
        next if line.match?(/\A%[-A-Za-z$._0-9]+\s*=\s*type\b/)
        next if line.match?(/\A#dbg_[A-Za-z0-9_.]+\b/)
        next if line.match?(/\A[@%][-A-Za-z$._0-9]+\s*=/) && !line.include?(" = ")
        message = llvm_static_unsupported_type_message(line)
        next(llvm_check_diagnostic(line: line_number, line_text: line, message:)) if message
        if line.match?(/\bvolatile\b/) && line.match?(/\A(?:#{PFC::Backend::LLVMCEmitter::NAME}\s*=\s*)?(?:load|store)\b/)
          next llvm_check_diagnostic(line: line_number, line_text: line, message: "volatile memory access is accepted as backend-equivalent, not target-volatile")
        end
        next if llvm_static_supported_line?(line)

        llvm_check_diagnostic(line: line_number, line_text: line, message: llvm_static_check_message(line))
      end
    end

    def llvm_check_diagnostic(line:, line_text:, message:)
      {
        severity: llvm_diagnostic_severity(message, line_text),
        line:,
        opcode: llvm_diagnostic_opcode(line_text || message),
        message:,
        hint: llvm_diagnostic_hint(message, line_text),
        explanation: llvm_diagnostic_explanation(message, line_text),
        fix_suggestions: llvm_fix_suggestions(message, line_text),
        line_text:
      }
    end

    def llvm_diagnostic_opcode(text)
      return nil if text.nil? || text.empty?

      text[/\A(?:[@%][-A-Za-z$._0-9]+\s*=\s*)?([A-Za-z0-9_.]+)/, 1] || "unknown"
    end

    def llvm_diagnostic_severity(message, line_text)
      text = [message, line_text].compact.join("\n")
      return "warning" if text.include?("backend-equivalent") || text.match?(/\bvolatile\b/)

      "error"
    end

    def llvm_diagnostic_hint(message, line_text)
      text = [message, line_text].compact.join("\n")
      return "Use supported fixed-length integer vector operations or explicitly lower vectors to scalar code." if text.include?("vector") || text.match?(/<\d+\s+x\s+i(?:1|8|16|32|64)>/)
      return "Lower floating-point operations to integer code before invoking pfc." if text.include?("floating-point")
      return "Use only supported i128 load/store, zeroinitializer, add/sub, bitwise and/or/xor, signed/unsigned comparisons, select, zext/sext, or truncation to a supported integer width." if text.include?("i128")
      return "blockaddress is outside the subset; use normal labels and branches." if text.include?("blockaddress")
      return "Provide a definition for the global or replace it with a supported local/global pointer." if text.include?("external global")
      return "Only the default address space is supported." if text.include?("address space")

      "Run `pfc llvm-capabilities` for supported syntax and lower this construct before compiling."
    end

    def llvm_diagnostic_explanation(message, line_text)
      text = [message, line_text].compact.join("\n")
      return "Scalable vectors, non-integer vector lanes, and unsupported vector opcodes do not have a stable lowering in this subset." if text.include?("scalable vector") || text.include?("unsupported vector") || text.match?(/<\d+\s+x\s+i(?:1|8|16|32|64)>/)
      return "The backend models integer operations with unsigned host scalars, so floating-point semantics are intentionally not lowered." if text.include?("floating-point")
      return "i128 is represented as low and high 64-bit halves for memory movement, add/sub, bitwise operations, signed/unsigned comparisons, selection, extension, and narrowing." if text.include?("i128")
      return "blockaddress exposes function-local control-flow addresses, which the generated C scheduler does not model." if text.include?("blockaddress")
      return "Declaration-only globals would require linker/runtime storage that this standalone C emitter cannot allocate safely." if text.include?("external global")
      return "Non-zero address spaces require target-specific pointer provenance that is outside the portable C backend." if text.include?("address space")

      "This instruction is outside the documented LLVM subset and must be lowered before pfc compiles it."
    end

    def llvm_fix_suggestions(message, line_text)
      text = [message, line_text].compact.join("\n")
      if text.match?(/\b(add|sub|mul|[us]div|[us]rem|and|or|xor|shl|lshr|ashr)\s+<\d+\s+x\s+i(?:1|8|16|32|64)>/)
        return [
          "replace vector arithmetic with extractelement per lane, scalar operations, and insertelement reconstruction",
          "or compile the source without vectorization before passing LLVM IR to pfc"
        ]
      end
      return ["rewrite floating-point work as integer or fixed-point operations before LLVM lowering"] if text.include?("floating-point")
      return ["truncate i128 to i64 before unsupported operations, or keep it limited to load/store, add/sub, and/or/xor, signed/unsigned comparisons, select, zext/sext, and trunc"] if text.include?("i128")
      return ["replace blockaddress with explicit labels and branch/switch control flow"] if text.include?("blockaddress")
      return ["define the global in the module or pass the data through supported local/global storage"] if text.include?("external global")
      return ["lower non-zero address-space pointers to default address-space pointers before pfc"] if text.include?("address space")

      ["lower this construct to the documented scalar integer, pointer, aggregate, or libc subset"]
    end

    def llvm_static_supported_line?(line)
      line.match?(/\A(?:[@%][-A-Za-z$._0-9]+\s*=\s*)?(?:(?:tail|musttail|notail)\s+)?(?:alloca|getelementptr|load|store|extractelement|insertelement|extractvalue|insertvalue|add|sub|mul|udiv|sdiv|urem|srem|and|or|xor|shl|lshr|ashr|zext|sext|trunc|ptrtoint|inttoptr|bitcast|addrspacecast|freeze|icmp|select|phi|call|switch|br|ret|unreachable)\b/) ||
        line.match?(/\A[@%][-A-Za-z$._0-9]+\s*=.*\b(?:global|constant|alias)\b/)
    end

    def llvm_static_check_message(line)
      type_message = llvm_static_unsupported_type_message(line)
      return type_message if type_message
      return "unsupported blockaddress constant expression" if line.include?("blockaddress")
      return "unsupported atomic operation" if line.match?(/\b(?:fence|atomicrmw|cmpxchg)\b/)
      return "unsupported exception handling instruction" if line.match?(/\b(?:invoke|landingpad|resume|catchswitch|catchpad|cleanuppad|cleanupret|catchret)\b/)
      return "unsupported vector shuffle instruction" if line.match?(/\bshufflevector\b/)
      return "unsupported varargs instruction" if line.match?(/\bva_arg\b/)

      opcode = line[/\A(?:[@%][-A-Za-z$._0-9]+\s*=\s*)?([A-Za-z0-9_.]+)/, 1] || "unknown"
      "unsupported LLVM instruction #{opcode}. Nearest supported areas: integer scalar ops, pointer ops, aggregate memory, libc calls."
    end

    def llvm_static_unsupported_type_message(line)
      return "unsupported scalable vector type" if line.match?(/(?:^|\s)<vscale\s+x\s+/)
      return "unsupported vector type" if line.match?(/(?:^|\s)<\d+\s+x\s+(?!i(?:1|8|16|32|64)\b)[^>]+>/)
      return "unsupported floating-point type" if line.match?(/\b(?:half|float|double|fp128|x86_fp80|ppc_fp128)\b/)
      nil
    end

    def parse_options
      options = {
        backend: DEFAULT_BACKEND,
        cell_bits: 8,
        debug: false,
        optimize: true,
        strict_printf: false,
        tape_size: Backend::CEmitter::DEFAULT_TAPE_SIZE
      }

      parser = OptionParser.new do |opts|
        opts.on("-o PATH", "--output=PATH") { |path| options[:output] = path }
        opts.on("--backend=NAME") { |name| options[:backend] = name }
        opts.on("--no-opt") { options[:optimize] = false }
        opts.on("--tape-size=N", Integer) { |size| options[:tape_size] = size }
        opts.on("--cell-bits=N", Integer) { |bits| options[:cell_bits] = bits }
        opts.on("--strict-printf") { options[:strict_printf] = true }
        opts.on("--debug") { options[:debug] = true }
        opts.on("--cc=PATH") { |cc| options[:cc] = cc }
      end

      parser.parse!(@argv)
      validate_options!(options)
      options
    end

    def validate_options!(options)
      unless SUPPORTED_BACKENDS.include?(options[:backend])
        raise ArgumentError, "unsupported backend: #{options[:backend]}"
      end

      unless [8, 16, 32].include?(options[:cell_bits])
        raise ArgumentError, "only --cell-bits=8, --cell-bits=16, or --cell-bits=32 is supported"
      end
    end

    def validate_source_options!(source_path, options)
      return unless llvm_source?(source_path)

      unsupported = []
      unsupported << "--backend=#{options[:backend]}" unless options[:backend] == DEFAULT_BACKEND
      unsupported << "--cell-bits=#{options[:cell_bits]}" unless options[:cell_bits] == 8
      unsupported << "--strict-printf" if options[:strict_printf]
      unsupported << "--no-opt" unless options[:optimize]
      return if unsupported.empty?

      raise ArgumentError, "LLVM input does not support #{unsupported.join(', ')}"
    end

    def require_input_path!
      path = @argv.shift
      raise ArgumentError, "missing input file" if path.nil?
      raise ArgumentError, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?

      path
    end

    def compile_source(source, options, source_path: nil)
      if llvm_source?(source_path)
        return Backend::LLVMCEmitter.new(source, tape_size: options[:tape_size]).emit
      end

      program = compile_ir(source, options, source_path:)
      emitter_for(options).emit(program)
    end

    def emitter_for(options)
      if options[:backend] == "printf-threaded"
        return Backend::ThreadedCEmitter.new(
          tape_size: options[:tape_size],
          strict_printf: options[:strict_printf],
          cell_bits: options[:cell_bits]
        )
      end

      Backend::CEmitter.new(
        tape_size: options[:tape_size],
        strict_printf: options[:strict_printf],
        cell_bits: options[:cell_bits]
      )
    end

    def compile_ir(source, options, source_path: nil)
      program = parse_program(source, source_path)
      return program unless options[:optimize]

      Optimizer.optimize(program)
    end

    def parse_program(source, source_path)
      raise Frontend::LLVMSubset::ParseError, "LLVM inputs are compiled through the LLVM C emitter" if llvm_source?(source_path)

      Frontend::Brainfuck.parse(source)
    end

    def llvm_source?(source_path)
      File.extname(source_path.to_s) == ".ll"
    end

    def compile_c(c_path, output, cc:, debug:)
      FileUtils.mkdir_p(File.dirname(output)) unless File.dirname(output) == "."

      args = [cc || DEFAULT_CC, "-std=c11", "-Wall", "-Wextra", "-O0"]
      args.concat(["-g", "-fsanitize=address,undefined"]) if debug
      args.concat([c_path, "-o", output])

      system(*args)
      $CHILD_STATUS.exitstatus || 1
    end

    def default_executable_path(source_path)
      base = File.basename(source_path, File.extname(source_path))
      base.empty? ? "a.out" : base
    end

    def usage(message)
      warn "pfc: #{message}"
      warn help
      1
    end

    def help
      <<~HELP
        Usage:
          pfc compile INPUT -o OUTPUT.c
          pfc build INPUT -o OUTPUT
          pfc run INPUT
          pfc dump-ir INPUT
          pfc dump-cfg INPUT
          pfc dump-c INPUT
          pfc llvm-capabilities [--json]
          pfc llvm-capabilities --check [--json] [--format=json|sarif] [--fix-suggestions] [--emit-lowering-plan] INPUT.ll
          pfc llvm-capabilities --check-dir [--json] [--format=json|sarif] [--emit-lowering-plan] [--include=GLOB] [--exclude=GLOB] [--fail-on-warning] DIR
          pfc llvm-capabilities --explain INPUT.ll

        Options:
          --backend=printf-c-scheduler|printf-threaded
          --no-opt
          --tape-size=30000
          --cell-bits=8|16|32
          --strict-printf
          --debug
      HELP
    end

    def llvm_capabilities
      <<~TEXT
        LLVM subset capabilities:
          memory:
            - scalar and fixed-array alloca/load/store over i1/i8/i16/i32/i64, plus i128 load/store with high 64-bit preservation
            - byte-addressed numeric globals, with global writable and constant read-only
            - struct/array global initializers and aggregate load/store byte copies in main and internal functions
            - fixed-length integer vector alloca/load/store byte copies in main and internal functions
            - pointer load/store and pointer fields inside aggregates
            - read-only global string byte memory for load/getelementptr/ptrtoint
            - constant and dynamic getelementptr for integer, array, and struct element sizes
            - constant-expression getelementptr/bitcast/inttoptr pointer operands and global initializer relocations
            - llvm.memcpy.inline.* over local/global memory
            - named struct alloca and struct field getelementptr
            - constant-count alloca, with dynamic-count alloca reserving tape-size capacity
            - volatile load/store accepted as backend-equivalent memory access
            - llvm.memset.*, llvm.memcpy.*, llvm.memmove.* over local/global memory
            - llvm.lifetime.start/end accepted as no-op intrinsics
          values:
            - true/false/undef/poison/zeroinitializer scalar constants
            - add/sub/mul, signed/unsigned division and remainder
            - bitwise and/or/xor, shl/lshr/ashr
            - zext/sext/trunc, including trunc from i128 to supported integer widths
            - limited i128 zeroinitializer, add/sub, shl/lshr/ashr, and/or/xor, eq/ne, signed/unsigned comparisons, phi, select, zext/sext, and truncation with high 64-bit preservation
            - ptrtoint and tagged inttoptr for local/global/string pointer values
            - bitcast ptr-to-ptr
            - addrspacecast for default address-space pointers
            - integer and pointer icmp, including null pointer equality
            - integer and pointer select
            - pointer phi
            - freeze
            - llvm.smax/smin/umax/umin, llvm.abs, llvm.bswap, llvm.ctpop, llvm.ctlz, and llvm.cttz scalar intrinsics
            - extractvalue and insertvalue for scalar integer fields in aggregate values
            - fixed-length <N x i8/i16/i32/i64> literals, zeroinitializer, add/sub/mul/udiv/sdiv/urem/srem/and/or/xor/shl/lshr/ashr scalarization, vector icmp/select, extractelement, and insertelement with runtime index checks
          control:
            - br, switch, phi, ret
            - unreachable as runtime abort
            - tail/musttail/notail accepted as no-op call markers
            - void @main and nested non-recursive internal calls with integer/pointer/void returns plus aggregate/i128/vector returns and integer/pointer/i128/vector/aggregate arguments
          tolerance:
            - common value attributes accepted as no-ops
            - trailing LLVM metadata attachments accepted as no-ops
            - typed-pointer-style syntax accepted as ptr
            - getelementptr inbounds/nuw/nusw/inrange flags accepted as no-op subset flags
            - target datalayout used for pointer width and struct layout
            - module-level metadata and attributes blocks accepted as no-ops
            - common noundef/nonnull/dereferenceable-style value attributes accepted as no-ops
            - llvm.global_ctors and llvm.global_dtors accepted as no-op metadata globals
            - llvm-capabilities --check reports schema_version plus diagnostic summary, severity/opcode/hint/explanation/fix_suggestions/line_text in JSON mode
            - llvm-capabilities --check-dir supports summary counts, include/exclude globs, fail-on-warning, and SARIF output
            - llvm-capabilities --explain, --fix-suggestions, and --emit-lowering-plan print lowering guidance with replacement/risk/runtime-support metadata
            - explicit diagnostics for unsupported vector shapes/shuffles, floating-point, unsupported i128 operations, atomics, exception handling, varargs, blockaddress, external globals, and non-zero address spaces
            - llvm.assume, llvm.dbg.*, and #dbg_* debug records accepted as no-ops
            - llvm.expect.* accepted as identity intrinsic
          libc:
            - putchar, getchar, puts
            - static printf with %d/%i/%u/%x/%X/%o/%c/%s/%p/%%, hh/h/l/ll integer length modifiers, static or dynamic width and precision, and 0/-/+/space/# flags
      TEXT
    end

    def llvm_capabilities_data
      {
        memory: [
          "scalar and fixed-array alloca/load/store over i1/i8/i16/i32/i64, plus i128 load/store with high 64-bit preservation",
          "byte-addressed numeric globals with global writable and constant read-only semantics",
          "struct/array global initializers and aggregate load/store byte copies in main and internal functions",
          "fixed-length integer vector alloca/load/store byte copies in main and internal functions",
          "pointer load/store and pointer fields inside aggregates",
          "read-only global string byte memory for load/getelementptr/ptrtoint",
          "constant and dynamic getelementptr for integer, array, and struct element sizes",
          "constant-expression getelementptr/bitcast/inttoptr pointer operands and global initializer relocations",
          "llvm.memcpy.inline.* over local/global memory",
          "named struct alloca and struct field getelementptr",
          "constant-count alloca, with dynamic-count alloca reserving tape-size capacity",
          "volatile load/store accepted as backend-equivalent memory access",
          "llvm.memset.*, llvm.memcpy.*, llvm.memmove.* over local/global memory",
          "llvm.lifetime.start/end accepted as no-op intrinsics"
        ],
        values: [
          "true/false/undef/poison/zeroinitializer scalar constants",
          "add/sub/mul, signed/unsigned division and remainder",
          "bitwise and/or/xor, shl/lshr/ashr",
          "zext/sext/trunc, including trunc from i128 to supported integer widths",
          "limited i128 zeroinitializer, add/sub, shl/lshr/ashr, and/or/xor, eq/ne, signed/unsigned comparisons, phi, select, zext/sext, and truncation with high 64-bit preservation",
          "ptrtoint and tagged inttoptr for local/global/string pointer values",
          "bitcast ptr-to-ptr",
          "addrspacecast for default address-space pointers",
          "integer and pointer icmp, including null pointer equality",
          "integer and pointer select",
          "pointer phi",
          "freeze",
          "llvm.smax/smin/umax/umin, llvm.abs, llvm.bswap, llvm.ctpop, llvm.ctlz, and llvm.cttz scalar intrinsics",
          "extractvalue and insertvalue for scalar integer fields in aggregate values",
          "fixed-length <N x i8/i16/i32/i64> literals, zeroinitializer, add/sub/mul/udiv/sdiv/urem/srem/and/or/xor/shl/lshr/ashr scalarization, vector icmp/select, extractelement, and insertelement with runtime index checks"
        ],
        control: [
          "br, switch, phi, ret",
          "unreachable as runtime abort",
          "tail/musttail/notail accepted as no-op call markers",
          "void @main and nested non-recursive internal calls with integer/pointer/void returns plus aggregate/i128/vector returns and integer/pointer/i128/vector/aggregate arguments"
        ],
        tolerance: [
          "common value attributes accepted as no-ops",
          "trailing LLVM metadata attachments accepted as no-ops",
          "typed-pointer-style syntax accepted as ptr",
          "getelementptr inbounds/nuw/nusw/inrange flags accepted as no-op subset flags",
          "target datalayout used for pointer width and struct layout",
          "module-level metadata and attributes blocks accepted as no-ops",
          "common noundef/nonnull/dereferenceable-style value attributes accepted as no-ops",
          "llvm.global_ctors and llvm.global_dtors accepted as no-op metadata globals",
          "llvm-capabilities --check reports schema_version plus diagnostic summary, severity/opcode/hint/explanation/fix_suggestions/line_text in JSON mode",
          "llvm-capabilities --check-dir supports summary counts, include/exclude globs, fail-on-warning, and SARIF output",
          "llvm-capabilities --explain, --fix-suggestions, and --emit-lowering-plan print lowering guidance with replacement/risk/runtime-support metadata",
          "explicit diagnostics for unsupported vector shapes/shuffles, floating-point, unsupported i128 operations, atomics, exception handling, varargs, blockaddress, external globals, and non-zero address spaces",
          "llvm.assume, llvm.dbg.*, and #dbg_* debug records accepted as no-ops",
          "llvm.expect.* accepted as identity intrinsic"
        ],
        libc: [
          "putchar, getchar, puts",
          "static printf with %d/%i/%u/%x/%X/%o/%c/%s/%p/%%, hh/h/l/ll integer length modifiers, static or dynamic width and precision, and 0/-/+/space/# flags"
        ]
      }
    end
  end
end
