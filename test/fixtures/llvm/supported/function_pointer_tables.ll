@table = private constant [1 x ptr] [ptr @emit]

define i32 @emit(i32 %value) {
entry:
  %r = call i32 @putchar(i32 %value)
  ret i32 %r
}

define i32 @main() {
entry:
  %slot = getelementptr [1 x ptr], ptr @table, i64 0, i64 0
  %from_table = load ptr, ptr %slot, align 8
  br i1 true, label %left, label %right

left:
  br label %merge

right:
  br label %merge

merge:
  %chosen = phi ptr [ %from_table, %left ], [ @emit, %right ]
  %r = call i32 %chosen(i32 66)
  ret i32 0
}
