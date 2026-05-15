; Generated-style optimized fixture for samples/clang/optimized_smoke.c
source_filename = "samples/clang/optimized_smoke.c"
target datalayout = "e-m:o-i64:64-n32:64-S128"
target triple = "arm64-apple-macosx15.0.0"

declare i32 @putchar(i32)

define i32 @main() {
entry:
  %written = tail call i32 @putchar(i32 66)
  ret i32 0
}
