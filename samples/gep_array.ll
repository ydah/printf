declare i32 @putchar(i32)

define i32 @main() {
entry:
  %arr = alloca [3 x i8], align 1
  %p0 = getelementptr inbounds [3 x i8], ptr %arr, i64 0, i64 0
  %p1 = getelementptr inbounds [3 x i8], ptr %arr, i64 0, i64 1
  store i8 65, ptr %p0, align 1
  store i8 66, ptr %p1, align 1
  %v0 = load i8, ptr %p0, align 1
  %v1 = load i8, ptr %p1, align 1
  call i32 @putchar(i32 %v0)
  call i32 @putchar(i32 %v1)
  ret i32 0
}
