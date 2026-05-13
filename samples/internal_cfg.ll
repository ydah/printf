declare i32 @putchar(i32)

define i32 @choose(i32 %x) {
entry:
  %is_a = icmp eq i32 %x, 65
  br i1 %is_a, label %yes, label %no
yes:
  br label %merge
no:
  br label %merge
merge:
  %out = phi i32 [ 89, %yes ], [ 78, %no ]
  ret i32 %out
}

define i32 @main() {
entry:
  %v1 = call i32 @choose(i32 65)
  call i32 @putchar(i32 %v1)
  %v2 = call i32 @choose(i32 66)
  call i32 @putchar(i32 %v2)
  ret i32 0
}
