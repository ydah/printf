@.fmt = private unnamed_addr constant [8 x i8] c" %u %d\0A\00", align 1
declare i32 @putchar(i32)
declare i32 @printf(ptr, ...)

define i32 @main() {
entry:
  %slot = alloca i64, align 8
  store i64 4294967301, ptr %slot, align 8
  %wide = load i64, ptr %slot, align 8
  %minus = sub i64 0, 5
  %cmp = icmp eq i64 %wide, 4294967301
  %out = select i1 %cmp, i32 89, i32 78
  call i32 @putchar(i32 %out)
  %printed = call i32 (ptr, ...) @printf(ptr @.fmt, i64 %wide, i64 %minus)
  ret i32 0
}
