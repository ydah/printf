%Pair = type { i8, i8 }

define void @fill(ptr sret(%Pair) %out, i8 %value) {
entry:
  %left = insertvalue %Pair zeroinitializer, i8 65, 0
  %pair = insertvalue %Pair %left, i8 %value, 1
  store %Pair %pair, ptr %out
  ret void
}

define i8 @read_second(ptr byval(%Pair) %in) {
entry:
  %pair = load %Pair, ptr %in
  %value = extractvalue %Pair %pair, 1
  ret i8 %value
}

define i32 @main() {
entry:
  %slot = alloca %Pair, align 8
  call void @fill(ptr sret(%Pair) %slot, i8 66)
  %byte = call i8 @read_second(ptr byval(%Pair) %slot)
  %out = zext i8 %byte to i32
  call i32 @putchar(i32 %out)
  ret i32 0
}
