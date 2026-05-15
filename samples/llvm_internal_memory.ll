%Pair = type { i32, i32 }

declare i32 @putchar(i32)

define internal %Pair @bump_pair(%Pair %pair) {
entry:
  %slot = alloca %Pair, align 4
  store %Pair %pair, ptr %slot, align 4
  %loaded = load %Pair, ptr %slot, align 4
  %first = extractvalue %Pair %loaded, 0
  %next = add i32 %first, 1
  %out = insertvalue %Pair %loaded, i32 %next, 0
  ret %Pair %out
}

define i32 @main() {
entry:
  %pair0 = insertvalue %Pair undef, i32 65, 0
  %pair1 = insertvalue %Pair %pair0, i32 66, 1
  %pair = call %Pair @bump_pair(%Pair %pair1)
  %out = extractvalue %Pair %pair, 0
  call i32 @putchar(i32 %out)
  ret i32 0
}
