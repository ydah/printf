declare i32 @getchar()
declare i32 @putchar(i32)

define i32 @main() {
entry:
  %ch = call i32 @getchar()
  %is_a = icmp eq i32 %ch, 65
  br i1 %is_a, label %yes, label %no

yes:
  br label %merge

no:
  br label %merge

merge:
  %out = phi i32 [ 89, %yes ], [ 78, %no ]
  call i32 @putchar(i32 %out)
  ret i32 0
}
