@.msg = private unnamed_addr constant [4 x i8] c"Hi!\00", align 1

declare i32 @puts(ptr)

define i32 @main() {
entry:
  call i32 @puts(ptr @.msg)
  ret i32 0
}
