@external = external global i8

define i32 @main() {
entry:
  store i8 66, ptr @external, align 1
  %value = load i8, ptr @external, align 1
  %out = zext i8 %value to i32
  call i32 @putchar(i32 %out)
  ret i32 0
}
