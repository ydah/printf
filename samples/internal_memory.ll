declare i32 @putchar(i32)

define i32 @make() {
entry:
  %slot = alloca i32, align 4
  store i32 66, ptr %slot, align 4
  %value = load i32, ptr %slot, align 4
  ret i32 %value
}

define i32 @main() {
entry:
  %value = call i32 @make()
  call i32 @putchar(i32 %value)
  ret i32 0
}
