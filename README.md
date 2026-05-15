# printf Backend

`printf` is not just a printer. With `%n`, the number of characters printed becomes a value, and that value can be written back to memory. This project uses that behavior as a tiny educational compiler target.

The primary path compiles Brainfuck to C. Generated C uses ordinary C control flow as the scheduler, while cell updates and pointer writes go through `fprintf` with `%hhn` / `%hn` against memory owned by the generated program.

## Quick Start

```sh
bin/pfc compile samples/hello.bf -o hello.c
cc -std=c11 -Wall -Wextra -O0 hello.c -o hello
./hello
```

Or build and run directly:

```sh
bin/pfc run samples/hello.bf
```

## CLI

Commands:

- `compile INPUT -o OUTPUT.c`
- `build INPUT -o OUTPUT`
- `run INPUT`
- `dump-ir INPUT`
- `dump-cfg INPUT`
- `dump-c INPUT`
- `llvm-capabilities [--json]`
- `llvm-capabilities --check [--json] [--format=json|sarif] [--fix-suggestions] [--emit-lowering-plan] INPUT.ll`
- `llvm-capabilities --check-dir [--json] [--format=json|sarif] [--emit-lowering-plan] [--include=GLOB] [--exclude=GLOB] [--fail-on-warning] DIR`
- `llvm-capabilities --explain INPUT.ll`

Common examples:

```sh
bin/pfc run samples/hello.bf --strict-printf
bin/pfc run samples/hello.bf --backend=printf-threaded
bin/pfc run samples/hello.bf --cell-bits=16
bin/pfc dump-ir samples/hello.bf
bin/pfc dump-c samples/hello.bf
```

LLVM examples:

```sh
bin/pfc run samples/putchar.ll
printf A | bin/pfc run samples/dynamic_branch.ll
printf 1 | bin/pfc run samples/dynamic_gep.ll
bin/pfc run samples/internal_call.ll
bin/pfc run samples/printf_format.ll
bin/pfc run samples/clang_smoke.ll
bin/pfc llvm-capabilities
bin/pfc llvm-capabilities --json
bin/pfc llvm-capabilities --check samples/clang_smoke.ll
bin/pfc llvm-capabilities --check --json samples/clang_smoke.ll
bin/pfc llvm-capabilities --check-dir --json test/fixtures/llvm
bin/pfc llvm-capabilities --check-dir --format=sarif test/fixtures/llvm
bin/pfc llvm-capabilities --check-dir --include='supported/*.ll' --fail-on-warning test/fixtures/llvm
bin/pfc llvm-capabilities --check --fix-suggestions samples/clang_smoke.ll
bin/pfc llvm-capabilities --check --emit-lowering-plan samples/clang_smoke.ll
bin/pfc llvm-capabilities --explain samples/clang_smoke.ll
CLANG="clang" ruby script/generate_clang_fixture.rb samples/example.c samples/example.ll
make fixtures
make fixtures-check
```

Options:

- `--backend=printf-c-scheduler`
- `--backend=printf-threaded`
- `--no-opt`
- `--tape-size=30000`
- `--cell-bits=8`
- `--cell-bits=16`
- `--cell-bits=32`
- `--strict-printf`
- `--debug`

## LLVM IR Subset

`.ll` inputs are detected by extension and compiled through the experimental LLVM IR subset frontend.

Use `bin/pfc llvm-capabilities` for the full supported subset, `bin/pfc llvm-capabilities --json` for machine-readable output, `bin/pfc llvm-capabilities --check [--json] [--fix-suggestions] [--emit-lowering-plan] FILE.ll` to preflight an LLVM file, `bin/pfc llvm-capabilities --check-dir [--json] [--format=json|sarif] [--emit-lowering-plan] [--include=GLOB] [--exclude=GLOB] [--fail-on-warning] DIR` to preflight a fixture tree, or `bin/pfc llvm-capabilities --explain FILE.ll` for human-readable lowering guidance. At a high level, the subset supports:

- Memory: byte-addressed local memory, integer/pointer/aggregate/vector `alloca`/`load`/`store`, `i128` load/store with high 64-bit preservation, numeric globals, string globals, nested struct/array initializers, pointer fields, global initializer relocations, `getelementptr`, and `llvm.memset.*` / `llvm.memcpy.*` / `llvm.memcpy.inline.*` / `llvm.memmove.*`.
- Values: `i1`/`i8`/`i16`/`i32`/`i64`, limited `i128` zero/add/sub/bitwise/shift/signed-and-unsigned-compare/select/phi/zext/sext/truncation with high 64-bit preservation, fixed-length `<N x i8/i16/i32/i64>` literals / `zeroinitializer` / `add`/`sub`/`mul`/`udiv`/`sdiv`/`urem`/`srem`/`and`/`or`/`xor`/`shl`/`lshr`/`ashr` scalarization / vector `icmp` / vector `select` / `extractelement` / `insertelement` with runtime index checks, integer arithmetic, bitwise and shift operations, casts, pointer tagging via `ptrtoint` / `inttoptr`, pointer `bitcast`, default-address-space `addrspacecast`, `icmp`, `select`, `phi`, constants, `freeze`, `extractvalue`, `insertvalue`, and scalar `llvm.smax` / `llvm.smin` / `llvm.umax` / `llvm.umin` / `llvm.abs` / `llvm.bswap` / `llvm.ctpop` / `llvm.ctlz` / `llvm.cttz`.
- Control flow: `br`, `switch`, scalar, pointer, and limited `i128`/vector `phi`, `ret`, `unreachable`, and nested non-recursive internal calls with integer, pointer, `i128`, vector, and void returns.
- Clang tolerance: typed-pointer-style syntax, common `noundef` / `nonnull` / `dereferenceable`-style value attributes, `getelementptr` no-op flags, trailing metadata, module-level metadata, attributes blocks, `target datalayout`, aliases, no-op `llvm.assume` / `llvm.dbg.*` / `#dbg_*`, identity `llvm.expect.*`, and no-op `llvm.global_ctors` / `llvm.global_dtors` metadata globals.
- Libc surface: `putchar`, `getchar`, `puts`, and static `printf` formats for integer, character, string, pointer, width, precision, flags, and escaped percent cases.

Out-of-scope LLVM features should fail with explicit diagnostics rather than silently compiling. This includes unsupported vector shapes, floating-point types, unsupported `i128` operations, `blockaddress`, declaration-only external globals, and non-zero address spaces. JSON preflight diagnostics include `schema_version`, `summary`, `severity`, `opcode`, `hint`, `explanation`, `fix_suggestions`, and `line_text` fields. `--emit-lowering-plan` returns structured lowering operations and warning advisories with replacement strategy, risk, and runtime-support metadata for external tooling. `--format=sarif` emits SARIF 2.1.0 for code scanning integrations.

`make fixtures-check` verifies committed clang `.ll` fixtures are fresh across the `O0`/`O1`/`O2`/`Oz` matrix and then preflights them with `llvm-capabilities --check`.

The generated program still uses C control flow as the scheduler. It does not claim a single-call `printf` execution model, which would require implementation-dependent or undefined behavior outside this project's safety scope.

Generated C uses `tmpfile()` as the internal printf sink, so it does not depend on `/dev/null`.

## Safety Scope

This is an educational compiler demo, not an exploit toolkit. Generated format strings are static strings produced by the compiler, and `%n` writes only to arrays and variables allocated by the generated C program.

## Tests

```sh
make test
UPDATE_SNAPSHOTS=1 make test
```
