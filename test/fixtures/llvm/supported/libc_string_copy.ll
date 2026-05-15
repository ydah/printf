@b = private unnamed_addr constant [2 x i8] c"B\00", align 1
@c = private unnamed_addr constant [2 x i8] c"C\00", align 1
@d = private unnamed_addr constant [2 x i8] c"D\00", align 1

declare ptr @strcpy(ptr, ptr)
declare ptr @strncpy(ptr, ptr, i64)
declare ptr @strcat(ptr, ptr)
declare ptr @strncat(ptr, ptr, i64)
declare ptr @strdup(ptr)
declare i64 @strlen(ptr)

define i32 @main() {
entry:
  %buffer = alloca [8 x i8], align 1
  %tmp = alloca [4 x i8], align 1
  %dst = getelementptr [8 x i8], ptr %buffer, i64 0, i64 0
  %tmp0 = getelementptr [4 x i8], ptr %tmp, i64 0, i64 0
  %bp = getelementptr [2 x i8], ptr @b, i64 0, i64 0
  %cp = getelementptr [2 x i8], ptr @c, i64 0, i64 0
  %dp = getelementptr [2 x i8], ptr @d, i64 0, i64 0
  %copy = call ptr @strcpy(ptr %dst, ptr %bp)
  %cat = call ptr @strcat(ptr %copy, ptr %cp)
  %ncat = call ptr @strncat(ptr %cat, ptr %dp, i64 1)
  %limited = call ptr @strncpy(ptr %tmp0, ptr %bp, i64 2)
  %dup = call ptr @strdup(ptr %limited)
  %len = call i64 @strlen(ptr %dup)
  %ok = icmp eq i64 %len, 1
  %byte = load i8, ptr %ncat, align 1
  %wide = zext i8 %byte to i32
  %out = select i1 %ok, i32 %wide, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
