declare i32 @putchar(i32)

define i32 @main() {
entry:
  %mul = mul <2 x i8> <i8 8, i8 9>, <i8 8, i8 8>
  %divided = udiv <2 x i8> %mul, <i8 1, i8 1>
  %remainder = srem <2 x i8> %divided, <i8 65, i8 65>
  %shifted = lshr <2 x i8> %remainder, <i8 0, i8 0>
  %cmp = icmp ugt <2 x i8> %shifted, <i8 63, i8 63>
  %selected = select <2 x i1> %cmp, <2 x i8> %shifted, <2 x i8> <i8 65, i8 66>
  %out = extractelement <2 x i8> %selected, i32 1
  %wide = zext i8 %out to i32
  call i32 @putchar(i32 %wide)
  ret i32 0
}
