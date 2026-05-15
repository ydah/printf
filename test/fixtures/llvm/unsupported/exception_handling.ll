define i32 @main() {
entry:
  %x = landingpad { ptr, i32 } cleanup
  ret i32 0
}
