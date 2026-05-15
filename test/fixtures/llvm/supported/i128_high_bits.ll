@wide = global i128 18446744073709551682, align 16

declare i32 @putchar(i32)

define i32 @main() {
entry:
  %loaded = load i128, ptr @wide, align 16
  %same = icmp eq i128 %loaded, 18446744073709551682
  %different = icmp ne i128 %loaded, 66
  %first = select i1 %same, i8 66, i8 78
  %out = select i1 %different, i8 %first, i8 78
  %wide_out = zext i8 %out to i32
  call i32 @putchar(i32 %wide_out)
  ret i32 0
}
