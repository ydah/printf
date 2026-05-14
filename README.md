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
bin/pfc llvm-capabilities
bin/pfc llvm-capabilities --json
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
- `llvm-capabilities [--json]`

`.ll` inputs are detected by extension and compiled with the experimental LLVM IR subset frontend. The LLVM path supports byte-addressed local memory for scalar and fixed-array `alloca`/`load`/`store` over `i1`/`i8`/`i16`/`i32`/`i64`, byte-addressed global integer scalars and fixed integer arrays with `global` writable and `constant` read-only semantics, read-only global string byte memory for `load`/`getelementptr`/`ptrtoint`, constant or dynamic `getelementptr` with integer element sizes, volatile `load`/`store` as backend-equivalent memory access, local/global `llvm.memset.*`, `llvm.memcpy.*`, and `llvm.memmove.*` intrinsics, no-op `llvm.lifetime.start/end`, scalar constants `true`/`false`/`undef`/`poison`/`zeroinitializer`, `add`/`sub`/`mul`/division/remainder, bitwise and shift operations with common `nuw`/`nsw`/`exact` flags accepted as subset no-ops, `zext`/`sext`/`trunc`, tagged `ptrtoint`/`inttoptr` for local/global/string pointer values, `bitcast ptr-to-ptr`, integer and pointer `icmp` including `null`, integer and pointer `select`, `switch`, `br`, simple `phi`, `ret`, `unreachable` as runtime abort, no-op `tail`/`musttail`/`notail` call markers, common value attributes and trailing metadata attachments as no-ops, `void @main`, nested internal integer/pointer and `void` calls with local CFG and memory, global `i8` string constants for direct `puts` and static `printf` calls with decimal `%d`/`%i`/`%u`, short and long integer length modifiers `%hhd`/`%hd`/`%ld`/`%lld`, radix `%x`/`%X`/`%o` and length variants, static or dynamic width, `0`/`-`/`+`/space/`#` flags, static or dynamic precision, `%c`/`%s`/`%p`/`%%`, and `putchar`/`getchar`.

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
