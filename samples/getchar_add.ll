declare i32 @getchar()
declare i32 @putchar(i32)

define i32 @main() {
entry:
  %ch = call i32 @getchar()
  %next = add i32 %ch, 1
  call i32 @putchar(i32 %next)
  ret i32 0
}
