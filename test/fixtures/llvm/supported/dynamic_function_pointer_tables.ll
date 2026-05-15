@table = private constant [2 x ptr] [ptr @emit_n, ptr @emit_b]

define i32 @emit_n() {
entry:
  %r = call i32 @putchar(i32 78)
  ret i32 %r
}

define i32 @emit_b() {
entry:
  %r = call i32 @putchar(i32 66)
  ret i32 %r
}

define i32 @main() {
entry:
  %index = zext i1 true to i64
  %slot = getelementptr [2 x ptr], ptr @table, i64 0, i64 %index
  %fn = load ptr, ptr %slot, align 8
  %r = call i32 %fn()
  ret i32 0
}
