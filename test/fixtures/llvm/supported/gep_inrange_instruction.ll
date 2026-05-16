@.buffer = global [2 x i8] c"AB", align 1

declare i32 @putchar(i32)

define i32 @main() {
entry:
  %ptr = getelementptr inbounds inrange(0, 2) [2 x i8], ptr @.buffer, i64 0, i64 1
  %value = load i8, ptr %ptr, align 1
  %wide = zext i8 %value to i32
  call i32 @putchar(i32 %wide)
  ret i32 0
}
