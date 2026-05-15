%Box = type { <2 x ptr> }

@a = private unnamed_addr constant [2 x i8] c"A\00", align 1
@b = private unnamed_addr constant [2 x i8] c"B\00", align 1

define <2 x ptr> @pick_vector(i1 %use_left, <2 x ptr> %left, <2 x ptr> %right) {
entry:
  br i1 %use_left, label %left_block, label %right_block

left_block:
  br label %join

right_block:
  br label %join

join:
  %picked = phi <2 x ptr> [ %left, %left_block ], [ %right, %right_block ]
  ret <2 x ptr> %picked
}

define i32 @main() {
entry:
  %ap = getelementptr [2 x i8], ptr @a, i64 0, i64 0
  %bp = getelementptr [2 x i8], ptr @b, i64 0, i64 0
  %left0 = insertelement <2 x ptr> zeroinitializer, ptr null, i32 0
  %left = insertelement <2 x ptr> %left0, ptr %ap, i32 1
  %right0 = insertelement <2 x ptr> zeroinitializer, ptr null, i32 0
  %right = insertelement <2 x ptr> %right0, ptr %bp, i32 1
  %chosen = call <2 x ptr> @pick_vector(i1 0, <2 x ptr> %left, <2 x ptr> %right)
  %box = insertvalue %Box zeroinitializer, <2 x ptr> %chosen, 0
  %field = extractvalue %Box %box, 0
  %is_same = icmp eq <2 x ptr> %field, %right
  %same_lane = extractelement <2 x i1> %is_same, i32 1
  %picked = extractelement <2 x ptr> %field, i32 1
  %byte = load i8, ptr %picked, align 1
  %wide = zext i8 %byte to i32
  %out = select i1 %same_lane, i32 %wide, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
