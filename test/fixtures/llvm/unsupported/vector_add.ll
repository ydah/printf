define i32 @main() {
entry:
  %x = udiv <2 x i32> <i32 8, i32 4>, <i32 2, i32 2>
  ret i32 0
}
