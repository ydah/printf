@base = global i128 18446744073709551615, align 16

declare i32 @putchar(i32)

define i32 @main() {
entry:
  %loaded = load i128, ptr @base, align 16
  %one = zext i8 1 to i128
  %sum = add i128 %loaded, %one
  %back = sub i128 %sum, %one
  %negative = sext i8 -1 to i128
  %signed_less = icmp slt i128 %negative, %sum
  %signed_greater = icmp sgt i128 %sum, %negative
  %unsigned_greater = icmp ugt i128 %sum, %back
  %first = and i1 %signed_less, %signed_greater
  %ok = and i1 %first, %unsigned_greater
  %out = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
