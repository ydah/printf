declare i32 @putchar(i32)

define i32 @main() {
entry:
  %sum = add <2 x i8> <i8 1, i8 2>, <i8 64, i8 64>
  %value = extractelement <2 x i8> %sum, i32 1
  %wide = zext i8 %value to i32
  call i32 @putchar(i32 %wide)
  ret i32 0
}
