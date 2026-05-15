define i32 @main() {
entry:
  %r = invoke nounwind i32 @putchar(i32 66) to label %done unwind label %unused

done:
  ret i32 0

unused:
  ret i32 1
}
