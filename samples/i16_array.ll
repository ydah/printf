declare i32 @putchar(i32)

define i32 @main() {
entry:
  %arr = alloca [2 x i16], align 2
  %p0 = getelementptr inbounds [2 x i16], ptr %arr, i64 0, i64 0
  %p1 = getelementptr inbounds [2 x i16], ptr %arr, i64 0, i64 1
  store i16 65, ptr %p0, align 2
  store i16 66, ptr %p1, align 2
  %v0 = load i16, ptr %p0, align 2
  %v1 = load i16, ptr %p1, align 2
  call i32 @putchar(i32 %v0)
  call i32 @putchar(i32 %v1)
  ret i32 0
}
