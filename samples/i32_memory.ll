declare i32 @putchar(i32)

define i32 @main() {
entry:
  %slot = alloca i32, align 4
  store i32 300, ptr %slot, align 4
  %value = load i32, ptr %slot, align 4
  %out = urem i32 %value, 256
  call i32 @putchar(i32 %out)
  ret i32 0
}
