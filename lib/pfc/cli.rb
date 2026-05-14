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
      raise ArgumentError, "unexpected arguments: #{@argv.join(' ')}" unless @argv.empty?

      puts llvm_capabilities
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
          pfc llvm-capabilities

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
            - scalar and fixed-array alloca/load/store over i1/i8/i16/i32/i64
            - byte-addressed numeric globals, with global writable and constant read-only
            - constant and dynamic getelementptr for integer element sizes
            - llvm.memset.*, llvm.memcpy.*, llvm.memmove.* over local/global memory
          values:
            - add/sub/mul, signed/unsigned division and remainder
            - bitwise and/or/xor, shl/lshr/ashr
            - zext/sext/trunc
            - ptrtoint and local-offset inttoptr
            - icmp and select
          control:
            - br, switch, phi, ret
            - void @main and nested non-recursive internal calls
          libc:
            - putchar, getchar, puts
            - static printf with %d/%i/%u/%x/%X/%o/%c/%s/%%, l/ll integer length modifiers, static width, 0/- flags, and static precision
      TEXT
    end
  end
end
