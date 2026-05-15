declare i32 @putchar(i32)

define i32 @main() {
entry:
  %value = extractelement <2 x i8> <i8 65, i8 66>, i32 1
  %wide = zext i8 %value to i32
  call i32 @putchar(i32 %wide)
  ret i32 0
}
