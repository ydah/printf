@letter = private unnamed_addr constant [2 x i8] c"B\00", align 1

define i32 @main() {
entry:
  %ptr = getelementptr [2 x i8], ptr @letter, i64 0, i64 0
  %with_null = insertelement <2 x ptr> zeroinitializer, ptr null, i32 0
  %with_ptr = insertelement <2 x ptr> %with_null, ptr %ptr, i32 1
  %selected = select <2 x i1> <i1 0, i1 1>, <2 x ptr> %with_ptr, <2 x ptr> zeroinitializer
  %picked = extractelement <2 x ptr> %selected, i32 1
  %byte = load i8, ptr %picked, align 1
  %out = zext i8 %byte to i32
  call i32 @putchar(i32 %out)
  ret i32 0
}
