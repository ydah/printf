define i32 @main() {
entry:
  %fp0 = bitcast ptr @putchar to ptr
  %fp = select i1 true, ptr %fp0, ptr @putchar
  %r = call i32 %fp(i32 66)
  ret i32 0
}
