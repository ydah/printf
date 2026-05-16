# printf Backend

`printf` is not just a printer. With `%n`, the number of characters printed becomes a value, and that value can be written back to memory. This project uses that behavior as a small educational compiler target.

The main compiler path translates Brainfuck to C. Generated C uses ordinary C control flow as the scheduler, while cell updates and pointer writes go through `fprintf` with `%hhn` / `%hn` against memory owned by the generated program.

The project also includes an experimental LLVM IR subset frontend for small integer-oriented `.ll` programs.

## Quick Start

```sh
bin/pfc compile samples/hello.bf -o hello.c
cc -std=c11 -Wall -Wextra -O0 hello.c -o hello
./hello
```

Run directly:

```sh
bin/pfc run samples/hello.bf
```

## CLI

Core commands:

- `compile INPUT -o OUTPUT.c`
- `build INPUT -o OUTPUT`
- `run INPUT`
- `dump-ir INPUT`
- `dump-cfg INPUT`
- `dump-c INPUT`
- `llvm-capabilities [OPTIONS]`

Common options:

- `--backend=printf-c-scheduler|printf-threaded`
- `--cell-bits=8|16|32`
- `--tape-size=30000`
- `--strict-printf`
- `--no-opt`
- `--debug`

Brainfuck examples:

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
bin/pfc run samples/clang_smoke.ll
bin/pfc llvm-capabilities
bin/pfc llvm-capabilities --check samples/clang_smoke.ll
bin/pfc llvm-capabilities --check --json samples/clang_smoke.ll
bin/pfc llvm-capabilities --check-dir --format=sarif test/fixtures/llvm
bin/pfc llvm-capabilities --coverage-report --json test/fixtures/llvm
bin/pfc llvm-capabilities --suggest-next --json test/fixtures/llvm
bin/pfc llvm-capabilities --explain samples/clang_smoke.ll
```

## LLVM IR Subset

`.ll` inputs are detected by extension and compiled through the LLVM C emitter.

The LLVM path is experimental and intentionally conservative. It is meant for small integer-oriented programs that can be lowered to standalone portable C. Unsupported constructs should fail with explicit diagnostics instead of compiling silently.

### What works

The supported subset focuses on:

- Integer, pointer, aggregate, and limited vector memory.
- Local and global byte-addressed storage.
- String and numeric globals, including common aggregate initializers.
- Integer scalar operations, casts, comparisons, `select`, `phi`, and common integer intrinsics.
- Limited `i128` support for storage and simple integer operations.
- `br`, `switch`, `ret`, `unreachable`, and `nounwind invoke`.
- Non-recursive internal calls and limited indirect calls through known function pointers.
- Common libc-style I/O, string, memory, ctype, heap, and static `printf` formats.
- Common Clang-generated noise such as metadata, attributes, typed-pointer spelling, lifetime/debug intrinsics, aliases, and global ctor/dtor metadata.

For the exact current list, run:

```sh
bin/pfc llvm-capabilities
```

### Checking LLVM input

Use preflight commands before compiling unfamiliar IR:

```sh
bin/pfc llvm-capabilities --check samples/clang_smoke.ll
bin/pfc llvm-capabilities --check --json samples/clang_smoke.ll
bin/pfc llvm-capabilities --check-dir test/fixtures/llvm
bin/pfc llvm-capabilities --coverage-report test/fixtures/llvm
bin/pfc llvm-capabilities --suggest-next test/fixtures/llvm
```

Useful options:

- `--json` for machine-readable diagnostics.
- `--format=sarif` for code scanning.
- `--fix-suggestions` for rewrite hints.
- `--emit-lowering-plan` for structured lowering steps.
- `--validate-schema` to check JSON output against `docs/llvm-capabilities.schema.json`.

### Out of scope

These should be lowered before passing IR to `pfc`:

- Floating-point.
- General exception handling.
- Varargs IR, including `va_arg`.
- `blockaddress`.
- Non-zero address spaces.
- Unsupported vector shapes or operations.
- Unsupported `i128` operations.
- Unknown escaped local pointers.
- Unknown indirect call targets.

Some accepted LLVM constructs are backend-equivalent rather than target-exact. For example, volatile memory, single-thread atomics, `fence`, and `nounwind invoke` are lowered to portable C semantics and may appear as `info` diagnostics in preflight output.

## Fixtures

Committed clang fixtures can be regenerated and checked with:

```sh
CLANG="clang" ruby script/generate_clang_fixture.rb samples/example.c samples/example.ll
make fixtures
make fixtures-check
```

`make fixtures-check` prints the clang version, verifies committed clang `.ll` fixtures across the `O0`/`O1`/`O2`/`Oz` matrix, writes diagnostics under `out/fixture-diagnostics/`, reports all stale/preflight failures, and exits non-zero when anything fails.

## Safety Scope

This is an educational compiler demo, not an exploit toolkit. Generated format strings are static strings produced by the compiler, and `%n` writes only to arrays and variables allocated by the generated C program.

Generated C uses `tmpfile()` as the internal printf sink, so it does not depend on `/dev/null`.

## Tests

```sh
make test
UPDATE_SNAPSHOTS=1 make test
```
