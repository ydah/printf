@letter = private unnamed_addr constant [2 x i8] c"B\00", align 1

declare ptr @memset(ptr, i32, i64)
declare ptr @memcpy(ptr, ptr, i64)
declare ptr @memmove(ptr, ptr, i64)
declare i64 @strlen(ptr)

define i32 @main() {
entry:
  %buffer = alloca [4 x i8], align 1
  %dst = getelementptr [4 x i8], ptr %buffer, i64 0, i64 0
  %src = getelementptr [2 x i8], ptr @letter, i64 0, i64 0
  call ptr @memset(ptr %dst, i32 0, i64 4)
  %copied = call ptr @memcpy(ptr %dst, ptr %src, i64 2)
  %len = call i64 @strlen(ptr %copied)
  %is_one = icmp eq i64 %len, 1
  %moved = call ptr @memmove(ptr %dst, ptr %src, i64 1)
  %byte = load i8, ptr %moved, align 1
  %wide = zext i8 %byte to i32
  %out = select i1 %is_one, i32 %wide, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
