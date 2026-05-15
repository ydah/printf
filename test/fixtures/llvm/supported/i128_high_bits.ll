@wide = global i128 18446744073709551682, align 16

declare i32 @putchar(i32)

define i32 @main() {
entry:
  %loaded = load i128, ptr @wide, align 16
  %small = zext i8 66 to i128
  %negative = sext i8 -1 to i128
  %masked = and i128 %loaded, 18446744073709551682
  %same = icmp eq i128 %masked, 18446744073709551682
  %greater = icmp ugt i128 %masked, 66
  %negative_is_wide = icmp ugt i128 %negative, %masked
  %selected = select i1 %greater, i128 %masked, i128 %small
  %narrow = trunc i128 %selected to i32
  %first = select i1 %same, i32 %narrow, i32 78
  %out = select i1 %negative_is_wide, i32 %first, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
