%Pair = type { i8, i8 }

define i32 @main() {
entry:
  %a0 = insertvalue %Pair zeroinitializer, i8 66, 0
  %a = insertvalue %Pair %a0, i8 65, 1
  %b0 = insertvalue %Pair zeroinitializer, i8 66, 0
  %b = insertvalue %Pair %b0, i8 65, 1
  %c0 = insertvalue %Pair zeroinitializer, i8 65, 0
  %c = insertvalue %Pair %c0, i8 66, 1
  %same = icmp eq %Pair %a, %b
  %different = icmp ne %Pair %a, %c
  %ok = and i1 %same, %different
  %out = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
