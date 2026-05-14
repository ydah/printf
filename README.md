# printf Backend

printf is not just a printer. With `%n`, the number of characters printed becomes a value, and that value can be written back to memory. This project turns that feature into a tiny educational compiler target.

The MVP compiles Brainfuck to C. The generated C uses ordinary C control flow as the scheduler, but cell updates and pointer writes go through `fprintf` with `%hhn` / `%hn` against memory owned by the generated program.

## Usage

```sh
bin/pfc compile samples/hello.bf -o hello.c
cc -std=c11 -Wall -Wextra -O0 hello.c -o hello
./hello
```

Or let the CLI build and run it:

```sh
bin/pfc run samples/hello.bf
bin/pfc run samples/hello.bf --strict-printf
bin/pfc run samples/hello.bf --backend=printf-threaded
bin/pfc run samples/hello.bf --cell-bits=16
bin/pfc dump-ir samples/hello.bf
bin/pfc dump-c samples/hello.bf
bin/pfc dump-cfg samples/dynamic_branch.ll
bin/pfc run samples/putchar.ll
printf A | bin/pfc run samples/dynamic_branch.ll
bin/pfc run samples/ops_select.ll
printf 1 | bin/pfc run samples/dynamic_gep.ll
bin/pfc run samples/internal_call.ll
bin/pfc run samples/internal_cfg.ll
bin/pfc run samples/internal_memory.ll
bin/pfc run samples/internal_nested_call.ll
bin/pfc run samples/void_main.ll
bin/pfc run samples/string_puts.ll
bin/pfc run samples/printf_format.ll
bin/pfc run samples/i64_ops.ll
```

Supported commands:

- `compile INPUT -o OUTPUT.c`
- `build INPUT -o OUTPUT`
- `run INPUT`
- `dump-ir INPUT`
- `dump-cfg INPUT`
- `dump-c INPUT`

`.ll` inputs are detected by extension and compiled with the experimental LLVM IR subset frontend. The LLVM path supports scalar and fixed-array `alloca`/`load`/`store` for `i1`/`i8`/`i16`/`i32`/`i64`, constant or dynamic `getelementptr`, `add`/`sub`/`mul`/division/remainder, bitwise and shift operations with common `nuw`/`nsw`/`exact` flags accepted as subset no-ops, `icmp`, `select`, `switch`, `br`, simple `phi`, `ret`, `void @main`, nested internal integer and `void` calls with local CFG and memory, global `i8` string constants for direct `puts` and static `printf` calls with decimal `%d`/`%i`/`%u`, long decimal `%ld`/`%li`/`%lu`/`%lld`/`%lli`/`%llu`, radix `%x`/`%X`/`%o` and long radix variants, `%c`/`%s`/`%%`, and `putchar`/`getchar`.

The generated program still uses C control flow as the scheduler. It does not claim a single-call `printf` execution model, which would require implementation-dependent or undefined behavior outside this project's safety scope.

Generated C uses `tmpfile()` as the internal printf sink, so it does not depend on `/dev/null`.

Supported options:

- `--backend=printf-c-scheduler`
- `--backend=printf-threaded`
- `--no-opt`
- `--tape-size=30000`
- `--cell-bits=8`
- `--cell-bits=16`
- `--cell-bits=32`
- `--strict-printf`
- `--debug`

## Safety Scope

This is an educational compiler demo, not an exploit toolkit. Generated format strings are static strings produced by the compiler, and `%n` writes only to arrays and variables allocated by the generated C program.

## Tests

```sh
make test
```
