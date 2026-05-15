%Pair = type { i8, i8 }

define void @fill(ptr sret(%Pair) %out, i8 %value) {
entry:
  %left = insertvalue %Pair zeroinitializer, i8 65, 0
  %pair = insertvalue %Pair %left, i8 %value, 1
  store %Pair %pair, ptr %out
  ret void
}

define i8 @mutate_second(ptr byval(%Pair) %in) {
entry:
  %pair = load %Pair, ptr %in
  %value = extractvalue %Pair %pair, 1
  %changed = insertvalue %Pair %pair, i8 78, 1
  store %Pair %changed, ptr %in
  ret i8 %value
}

define i32 @main() {
entry:
  %slot = alloca %Pair, align 8
  call void @fill(ptr sret(%Pair) %slot, i8 66)
  %byte = call i8 @mutate_second(ptr byval(%Pair) %slot)
  %after = load %Pair, ptr %slot
  %still_original = extractvalue %Pair %after, 1
  %same = icmp eq i8 %byte, %still_original
  %wide = zext i8 %byte to i32
  %out = select i1 %same, i32 %wide, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
