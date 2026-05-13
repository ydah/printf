@.fmt = private unnamed_addr constant [24 x i8] c"n=%d u=%u c=%c s=%s %%\0A\00", align 1
@.word = private unnamed_addr constant [3 x i8] c"ok\00", align 1

declare i32 @printf(ptr, ...)

define i32 @main() {
entry:
  call i32 (ptr, ...) @printf(ptr @.fmt, i32 -7, i32 42, i32 65, ptr @.word)
  ret i32 0
}
