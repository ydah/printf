# LLVM check-dir and SARIF

```sh
bin/pfc llvm-capabilities --check-dir --json test/fixtures/llvm
bin/pfc llvm-capabilities --check-dir --format=sarif test/fixtures/llvm > llvm-capabilities.sarif
```

Use `--include=GLOB`, `--exclude=GLOB`, and `--fail-on-warning` to tune CI checks.
