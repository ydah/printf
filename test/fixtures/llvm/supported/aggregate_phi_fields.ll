%WideVec = type { i128, <2 x i8> }

declare i32 @putchar(i32)

define i32 @main() {
entry:
  %init0 = insertvalue %WideVec undef, i128 65, 0
  %init = insertvalue %WideVec %init0, <2 x i8> <i8 65, i8 66>, 1
  br label %loop

loop:
  %state = phi %WideVec [ %init, %entry ], [ %next, %loop ]
  %count = phi i32 [ 0, %entry ], [ %count_next, %loop ]
  %wide = extractvalue %WideVec %state, 0
  %vec = extractvalue %WideVec %state, 1
  %wide_next = add i128 %wide, 1
  %next0 = insertvalue %WideVec %state, i128 %wide_next, 0
  %next = insertvalue %WideVec %next0, <2 x i8> %vec, 1
  %count_next = add i32 %count, 1
  %done = icmp eq i32 %count_next, 1
  br i1 %done, label %exit, label %loop

exit:
  %final_wide = extractvalue %WideVec %next, 0
  %final_vec = extractvalue %WideVec %next, 1
  %wide_ok = icmp eq i128 %final_wide, 66
  %lane = extractelement <2 x i8> %final_vec, i32 1
  %lane32 = zext i8 %lane to i32
  %lane_ok = icmp eq i32 %lane32, 66
  %ok = and i1 %wide_ok, %lane_ok
  %out = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
