define i32 @main() {
entry:
  %x = add <2 x i32> <i32 1, i32 2>, <i32 3, i32 4>
  ret i32 0
}
