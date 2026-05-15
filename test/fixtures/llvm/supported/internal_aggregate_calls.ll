declare i32 @putchar(i32)

define internal i128 @wide_twice(i128 %value) {
entry:
  %shifted = shl i128 %value, 1
  ret i128 %shifted
}

define internal <2 x i8> @pick(<2 x i8> %left, <2 x i8> %right) {
entry:
  %cmp = icmp ugt <2 x i8> %left, <i8 64, i8 64>
  %selected = select <2 x i1> %cmp, <2 x i8> %left, <2 x i8> %right
  ret <2 x i8> %selected
}

define i32 @main() {
entry:
  %wide = call i128 @wide_twice(i128 33)
  %is_wide = icmp eq i128 %wide, 66
  %vector = call <2 x i8> @pick(<2 x i8> <i8 66, i8 65>, <2 x i8> <i8 78, i8 78>)
  %lane = extractelement <2 x i8> %vector, i32 0
  %char = zext i8 %lane to i32
  %out = select i1 %is_wide, i32 %char, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
