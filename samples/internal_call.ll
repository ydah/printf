declare i32 @putchar(i32)

define i32 @twice_plus_two(i32 %value) {
entry:
  %twice = add i32 %value, %value
  %out = add i32 %twice, 2
  ret i32 %out
}

define i32 @main() {
entry:
  %value = call i32 @twice_plus_two(i32 32)
  call i32 @putchar(i32 %value)
  ret i32 0
}
