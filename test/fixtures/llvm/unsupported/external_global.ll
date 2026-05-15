@external = external global i8

define i32 @main() {
entry:
  %x = load i8, ptr @external, align 1
  ret i32 0
}
