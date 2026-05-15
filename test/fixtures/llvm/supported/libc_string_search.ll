@text = private unnamed_addr constant [5 x i8] c"ABCA\00", align 1
@accept = private unnamed_addr constant [4 x i8] c"ABC\00", align 1
@reject = private unnamed_addr constant [2 x i8] c"C\00", align 1
@needles = private unnamed_addr constant [3 x i8] c"BC\00", align 1

declare ptr @strchr(ptr, i32)
declare ptr @strrchr(ptr, i32)
declare i64 @strspn(ptr, ptr)
declare i64 @strcspn(ptr, ptr)
declare ptr @strpbrk(ptr, ptr)

define i32 @main() {
entry:
  %textp = getelementptr [5 x i8], ptr @text, i64 0, i64 0
  %acceptp = getelementptr [4 x i8], ptr @accept, i64 0, i64 0
  %rejectp = getelementptr [2 x i8], ptr @reject, i64 0, i64 0
  %needlep = getelementptr [3 x i8], ptr @needles, i64 0, i64 0
  %first = call ptr @strchr(ptr %textp, i32 66)
  %first_byte = load i8, ptr %first, align 1
  %last = call ptr @strrchr(ptr %textp, i32 65)
  %last_byte = load i8, ptr %last, align 1
  %span = call i64 @strspn(ptr %textp, ptr %acceptp)
  %cspan = call i64 @strcspn(ptr %textp, ptr %rejectp)
  %brk = call ptr @strpbrk(ptr %textp, ptr %needlep)
  %brk_byte = load i8, ptr %brk, align 1
  %ok_first = icmp eq i8 %first_byte, 66
  %ok_last = icmp eq i8 %last_byte, 65
  %ok_span = icmp eq i64 %span, 4
  %ok_cspan = icmp eq i64 %cspan, 2
  %ok_brk = icmp eq i8 %brk_byte, 66
  %ok1 = and i1 %ok_first, %ok_last
  %ok2 = and i1 %ok_span, %ok_cspan
  %ok3 = and i1 %ok1, %ok2
  %ok = and i1 %ok3, %ok_brk
  %out = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
