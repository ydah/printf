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
bin/pfc dump-ir samples/hello.bf
bin/pfc dump-c samples/hello.bf
bin/pfc run samples/putchar.ll
printf A | bin/pfc run samples/dynamic_branch.ll
```

Supported commands:

- `compile INPUT -o OUTPUT.c`
- `build INPUT -o OUTPUT`
- `run INPUT`
- `dump-ir INPUT`
- `dump-c INPUT`

`.ll` inputs are detected by extension and compiled with the experimental LLVM IR subset frontend. The LLVM path supports scalar `alloca`/`load`/`store`, byte arrays with constant `getelementptr`, `add`/`sub`, `icmp eq/ne`, `br`, simple `phi`, `ret`, and `putchar`/`getchar`.

The generated program still uses C control flow as the scheduler. It does not claim a single-call `printf` execution model, which would require implementation-dependent or undefined behavior outside this project's safety scope.

Supported options:

- `--backend=printf-c-scheduler`
- `--backend=printf-threaded`
- `--no-opt`
- `--tape-size=30000`
- `--cell-bits=8`
- `--strict-printf`
- `--debug`

## Safety Scope

This is an educational compiler demo, not an exploit toolkit. Generated format strings are static strings produced by the compiler, and `%n` writes only to arrays and variables allocated by the generated C program.

## Tests

```sh
make test
```
