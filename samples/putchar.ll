declare i32 @putchar(i32)

define i32 @main() {
entry:
  %slot = alloca i8
  store i8 65, ptr %slot
  %value = load i8, ptr %slot
  %next = add i8 %value, 1
  call i32 @putchar(i32 %next)
  ret i32 0
}
