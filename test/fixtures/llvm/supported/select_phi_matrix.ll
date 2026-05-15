@b = private unnamed_addr constant [2 x i8] c"B\00", align 1
@n = private unnamed_addr constant [2 x i8] c"N\00", align 1

define i32 @main() {
entry:
  %bp = getelementptr [2 x i8], ptr @b, i64 0, i64 0
  %np = getelementptr [2 x i8], ptr @n, i64 0, i64 0
  %vec_b = insertelement <2 x ptr> zeroinitializer, ptr %bp, i32 0
  %vec_n = insertelement <2 x ptr> zeroinitializer, ptr %np, i32 0
  br i1 true, label %left, label %right

left:
  br label %merge

right:
  br label %merge

merge:
  %phi_p = phi ptr [ %bp, %left ], [ %np, %right ]
  %phi_v = phi <2 x ptr> [ %vec_b, %left ], [ %vec_n, %right ]
  %sel_p = select i1 true, ptr %phi_p, ptr %np
  %sel_v = select i1 true, <2 x ptr> %phi_v, <2 x ptr> %vec_n
  %from_vec = extractelement <2 x ptr> %sel_v, i32 0
  %same = icmp eq ptr %sel_p, %from_vec
  %byte = load i8, ptr %sel_p, align 1
  %wide = zext i8 %byte to i32
  %out = select i1 %same, i32 %wide, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
