@num = private unnamed_addr constant [3 x i8] c"66\00", align 1
@hex = private unnamed_addr constant [5 x i8] c"0x42\00", align 1

declare i32 @atoi(ptr)
declare i64 @strtol(ptr, ptr, i32)
declare i32 @isdigit(i32)
declare i32 @isalpha(i32)
declare i32 @isalnum(i32)
declare i32 @isspace(i32)
declare i32 @toupper(i32)
declare i32 @tolower(i32)

define i32 @main() {
entry:
  %nump = getelementptr [3 x i8], ptr @num, i64 0, i64 0
  %hexp = getelementptr [5 x i8], ptr @hex, i64 0, i64 0
  %atoi = call i32 @atoi(ptr %nump)
  %atoi_ok = icmp eq i32 %atoi, 66
  %strtol = call i64 @strtol(ptr %hexp, ptr null, i32 16)
  %strtol_ok = icmp eq i64 %strtol, 66
  %digit = call i32 @isdigit(i32 54)
  %alpha = call i32 @isalpha(i32 98)
  %alnum = call i32 @isalnum(i32 66)
  %space = call i32 @isspace(i32 32)
  %upper = call i32 @toupper(i32 98)
  %lower = call i32 @tolower(i32 66)
  %upper_ok = icmp eq i32 %upper, 66
  %lower_ok = icmp eq i32 %lower, 98
  %d_ok = icmp ne i32 %digit, 0
  %a_ok = icmp ne i32 %alpha, 0
  %an_ok = icmp ne i32 %alnum, 0
  %s_ok = icmp ne i32 %space, 0
  %ok1 = and i1 %atoi_ok, %strtol_ok
  %ok2 = and i1 %d_ok, %a_ok
  %ok3 = and i1 %an_ok, %s_ok
  %ok4 = and i1 %upper_ok, %lower_ok
  %ok5 = and i1 %ok1, %ok2
  %ok6 = and i1 %ok3, %ok4
  %ok = and i1 %ok5, %ok6
  %out = select i1 %ok, i32 %upper, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
