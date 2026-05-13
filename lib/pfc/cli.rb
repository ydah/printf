# frozen_string_literal: true

require "English"
require "fileutils"
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
      when "dump-c"
        dump_c_command
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
      if llvm_source?(source_path)
        puts Backend::LLVMCEmitter.new(File.read(source_path), tape_size: options[:tape_size]).dump_ir
        return 0
      end

      puts compile_ir(File.read(source_path), options, source_path:).inspect
      0
    end

    def dump_c_command
      options = parse_options
      source_path = require_input_path!
      puts compile_source(File.read(source_path), options, source_path:)
      0
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

      raise ArgumentError, "only --cell-bits=8 or --cell-bits=16 is supported" unless [8, 16].include?(options[:cell_bits])
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
          pfc dump-c INPUT

        Options:
          --backend=printf-c-scheduler|printf-threaded
          --no-opt
          --tape-size=30000
          --cell-bits=8|16
          --strict-printf
          --debug
      HELP
    end
  end
end
