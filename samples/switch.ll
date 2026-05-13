declare i32 @getchar()
declare i32 @putchar(i32)

define i32 @main() {
entry:
  %ch = call i32 @getchar()
  switch i32 %ch, label %other [
    i32 65, label %a
    i32 66, label %b
  ]

a:
  br label %merge

b:
  br label %merge

other:
  br label %merge

merge:
  %out = phi i32 [ 88, %a ], [ 89, %b ], [ 90, %other ]
  call i32 @putchar(i32 %out)
  ret i32 0
}
