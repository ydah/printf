declare i32 @getchar()
declare i32 @putchar(i32)

define i32 @main() {
entry:
  %arr = alloca [3 x i8], align 1
  %p0 = getelementptr inbounds [3 x i8], ptr %arr, i64 0, i64 0
  %p1 = getelementptr inbounds [3 x i8], ptr %arr, i64 0, i64 1
  %p2 = getelementptr inbounds [3 x i8], ptr %arr, i64 0, i64 2
  store i8 65, ptr %p0, align 1
  store i8 66, ptr %p1, align 1
  store i8 67, ptr %p2, align 1
  %ch = call i32 @getchar()
  %idx = sub i32 %ch, 48
  %p = getelementptr inbounds [3 x i8], ptr %arr, i64 0, i32 %idx
  %value = load i8, ptr %p, align 1
  call i32 @putchar(i32 %value)
  ret i32 0
}
