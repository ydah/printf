declare i32 @putchar(i32)

define i32 @main() {
entry:
  switch i32 4, label %default [
    i32 0, label %default
    i32 1, label %default
    i32 2, label %default
    i32 3, label %default
    i32 4, label %hit
  ]
hit:
  call i32 @putchar(i32 66)
  ret i32 0
default:
  call i32 @putchar(i32 78)
  ret i32 0
}
