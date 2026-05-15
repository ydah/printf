define i32 @main() {
entry:
  %x = ptrtoint ptr blockaddress(@main, %entry) to i64
  ret i32 0
}
