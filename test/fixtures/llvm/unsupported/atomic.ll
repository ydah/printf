define i32 @main() {
entry:
  fence seq_cst
  ret i32 0
}
