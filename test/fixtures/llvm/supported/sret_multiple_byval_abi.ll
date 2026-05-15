%Pair = type { i8, i8 }

define void @combine(ptr sret(%Pair) %out, ptr byval(%Pair) %left, ptr byval(%Pair) %right) {
entry:
  %left_value = load %Pair, ptr %left, align 1
  %right_value = load %Pair, ptr %right, align 1
  %first = extractvalue %Pair %left_value, 0
  %second = extractvalue %Pair %right_value, 1
  %tmp = insertvalue %Pair zeroinitializer, i8 %first, 0
  %result = insertvalue %Pair %tmp, i8 %second, 1
  store %Pair %result, ptr %out, align 1
  store %Pair zeroinitializer, ptr %left, align 1
  store %Pair zeroinitializer, ptr %right, align 1
  ret void
}

define i32 @main() {
entry:
  %left = alloca %Pair, align 1
  %right = alloca %Pair, align 1
  %out = alloca %Pair, align 1
  %left0 = insertvalue %Pair zeroinitializer, i8 66, 0
  %left_value = insertvalue %Pair %left0, i8 65, 1
  %right0 = insertvalue %Pair zeroinitializer, i8 65, 0
  %right_value = insertvalue %Pair %right0, i8 66, 1
  store %Pair %left_value, ptr %left, align 1
  store %Pair %right_value, ptr %right, align 1
  call void @combine(ptr sret(%Pair) %out, ptr byval(%Pair) %left, ptr byval(%Pair) %right)
  %combined = load %Pair, ptr %out, align 1
  %combined_second = extractvalue %Pair %combined, 1
  %left_after = load %Pair, ptr %left, align 1
  %right_after = load %Pair, ptr %right, align 1
  %left_first = extractvalue %Pair %left_after, 0
  %right_second = extractvalue %Pair %right_after, 1
  %ok_combined = icmp eq i8 %combined_second, 66
  %ok_left = icmp eq i8 %left_first, 66
  %ok_right = icmp eq i8 %right_second, 66
  %ok1 = and i1 %ok_combined, %ok_left
  %ok = and i1 %ok1, %ok_right
  %result = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %result)
  ret i32 0
}
