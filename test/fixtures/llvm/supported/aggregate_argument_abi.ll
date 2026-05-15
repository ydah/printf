%Pair = type { i8, i8 }

define i8 @pick(%Pair %pair) {
entry:
  %value = extractvalue %Pair %pair, 1
  ret i8 %value
}

define i32 @main() {
entry:
  %left = insertvalue %Pair zeroinitializer, i8 65, 0
  %pair = insertvalue %Pair %left, i8 66, 1
  %byte = call i8 @pick(%Pair %pair)
  %out = zext i8 %byte to i32
  call i32 @putchar(i32 %out)
  ret i32 0
}
