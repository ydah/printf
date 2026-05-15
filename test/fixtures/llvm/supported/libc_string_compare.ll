@left = private unnamed_addr constant [3 x i8] c"B\00\00", align 1
@right = private unnamed_addr constant [3 x i8] c"B\00\00", align 1
@longer = private unnamed_addr constant [3 x i8] c"BC\00", align 1
@haystack = private unnamed_addr constant [3 x i8] c"XB\00", align 1

declare i32 @strcmp(ptr, ptr)
declare i32 @strncmp(ptr, ptr, i64)
declare i32 @memcmp(ptr, ptr, i64)
declare ptr @memchr(ptr, i32, i64)

define i32 @main() {
entry:
  %leftp = getelementptr [3 x i8], ptr @left, i64 0, i64 0
  %rightp = getelementptr [3 x i8], ptr @right, i64 0, i64 0
  %longp = getelementptr [3 x i8], ptr @longer, i64 0, i64 0
  %hayp = getelementptr [3 x i8], ptr @haystack, i64 0, i64 0
  %cmp = call i32 @strcmp(ptr %leftp, ptr %rightp)
  %same = icmp eq i32 %cmp, 0
  %ncmp = call i32 @strncmp(ptr %leftp, ptr %longp, i64 1)
  %prefix = icmp eq i32 %ncmp, 0
  %mcmp = call i32 @memcmp(ptr %leftp, ptr %rightp, i64 1)
  %bytes = icmp eq i32 %mcmp, 0
  %found = call ptr @memchr(ptr %hayp, i32 66, i64 2)
  %byte = load i8, ptr %found, align 1
  %wide = zext i8 %byte to i32
  %ok1 = and i1 %same, %prefix
  %ok = and i1 %ok1, %bytes
  %out = select i1 %ok, i32 %wide, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
