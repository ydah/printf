declare i32 @putchar(i32)

define i32 @double(i32 %x) {
entry:
  %value = add i32 %x, %x
  ret i32 %value
}

define i32 @make() {
entry:
  %value = call i32 @double(i32 33)
  ret i32 %value
}

define i32 @main() {
entry:
  %value = call i32 @make()
  call i32 @putchar(i32 %value)
  ret i32 0
}
