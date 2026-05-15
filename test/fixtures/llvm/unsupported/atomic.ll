define i32 @main() {
entry:
  %old = atomicrmw add ptr null, i32 1 seq_cst
  ret i32 0
}
