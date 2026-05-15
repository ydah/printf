@wide = global i128 18446744073709551682, align 16

declare i32 @putchar(i32)

define i32 @main() {
entry:
  %loaded = load i128, ptr @wide, align 16
  %masked = and i128 %loaded, 18446744073709551682
  %same = icmp eq i128 %masked, 18446744073709551682
  %greater = icmp ugt i128 %masked, 66
  %first = select i1 %same, i8 66, i8 78
  %out = select i1 %greater, i8 %first, i8 78
  %wide_out = zext i8 %out to i32
  call i32 @putchar(i32 %wide_out)
  ret i32 0
}
