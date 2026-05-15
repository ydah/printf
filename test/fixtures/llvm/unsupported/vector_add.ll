define i32 @main() {
entry:
  %x = shufflevector <2 x i32> <i32 1, i32 2>, <2 x i32> <i32 3, i32 4>, <2 x i32> <i32 0, i32 2>
  ret i32 0
}
