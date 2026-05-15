define i32 @main() {
entry:
  %x = add <2 x i128> <i128 1, i128 2>, <i128 3, i128 4>
  ret i32 0
}
