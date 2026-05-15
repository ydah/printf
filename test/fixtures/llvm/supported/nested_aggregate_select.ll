%Inner = type { i8, i128 }
%Outer = type { [2 x i32], %Inner }

define i32 @main() {
entry:
  %base = insertvalue %Outer zeroinitializer, i32 10, 0, 0
  %with_char = insertvalue %Outer %base, i32 66, 0, 1
  %with_flag = insertvalue %Outer %with_char, i8 7, 1, 0
  %expected = insertvalue %Outer %with_flag, i128 18446744073709551617, 1, 1
  %fallback = insertvalue %Outer zeroinitializer, i32 78, 0, 1
  %selected = select i1 1, %Outer %expected, %Outer %fallback
  %wide = extractvalue %Outer %selected, 1, 1
  %ok = icmp eq i128 %wide, 18446744073709551617
  %char = extractvalue %Outer %selected, 0, 1
  %out = select i1 %ok, i32 %char, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
