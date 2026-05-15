declare i32 @putchar(i32)

define i32 @main() {
entry:
  switch i8 255, label %miss [
    i8 -1, label %hit
  ]
hit:
  call i32 @putchar(i32 66)
  ret i32 0
miss:
  call i32 @putchar(i32 78)
  ret i32 0
}
