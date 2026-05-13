declare i32 @putchar(i32)

define void @main() {
entry:
  call i32 @putchar(i32 65)
  ret void
}
