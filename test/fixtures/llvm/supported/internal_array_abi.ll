declare i32 @putchar(i32)

define internal [2 x i32] @bump_array([2 x i32] %arr) {
entry:
  %first = extractvalue [2 x i32] %arr, 0
  %next = add i32 %first, 1
  %out = insertvalue [2 x i32] %arr, i32 %next, 0
  ret [2 x i32] %out
}

define i32 @main() {
entry:
  %arr0 = insertvalue [2 x i32] undef, i32 65, 0
  %arr1 = insertvalue [2 x i32] %arr0, i32 66, 1
  %arr = call [2 x i32] @bump_array([2 x i32] %arr1)
  %out = extractvalue [2 x i32] %arr, 0
  call i32 @putchar(i32 %out)
  ret i32 0
}
