declare i32 @putchar(i32)

define i32 @main() {
entry:
  %sum = add <2 x i8> <i8 1, i8 2>, <i8 64, i8 64>
  %same = sub <2 x i8> %sum, <i8 0, i8 0>
  %xored = xor <2 x i8> %same, <i8 0, i8 0>
  %ored = or <2 x i8> %xored, zeroinitializer
  %masked = and <2 x i8> %ored, <i8 255, i8 255>
  %value = extractelement <2 x i8> %masked, i32 1
  %wide = zext i8 %value to i32
  call i32 @putchar(i32 %wide)
  ret i32 0
}
