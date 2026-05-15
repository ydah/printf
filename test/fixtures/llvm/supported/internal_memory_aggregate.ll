%Pair = type { i32, i32 }

declare i32 @putchar(i32)

define internal i128 @roundtrip_wide(i128 %value) {
entry:
  %slot = alloca i128, align 16
  store i128 %value, ptr %slot, align 16
  %loaded = load i128, ptr %slot, align 16
  ret i128 %loaded
}

define internal <2 x i8> @roundtrip_vector(<2 x i8> %value) {
entry:
  %slot = alloca <2 x i8>, align 2
  store <2 x i8> %value, ptr %slot, align 2
  %loaded = load <2 x i8>, ptr %slot, align 2
  ret <2 x i8> %loaded
}

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
  %wide = call i128 @roundtrip_wide(i128 66)
  %wide_ok = icmp eq i128 %wide, 66
  %vector = call <2 x i8> @roundtrip_vector(<2 x i8> <i8 65, i8 66>)
  %lane = extractelement <2 x i8> %vector, i32 1
  %pair0 = insertvalue %Pair undef, i32 65, 0
  %pair1 = insertvalue %Pair %pair0, i32 66, 1
  %pair = call %Pair @bump_pair(%Pair %pair1)
  %field = extractvalue %Pair %pair, 0
  %lane32 = zext i8 %lane to i32
  %lane_ok = icmp eq i32 %lane32, 66
  %pair_ok = icmp eq i32 %field, 66
  %both0 = and i1 %wide_ok, %lane_ok
  %both1 = and i1 %both0, %pair_ok
  %out = select i1 %both1, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
