declare i32 @putchar(i32)

define i32 @main() {
entry:
  br label %loop

loop:
  %wide = phi i128 [ 1, %entry ], [ %next, %loop ]
  %count = phi i32 [ 0, %entry ], [ %count_next, %loop ]
  %next = shl i128 %wide, 1
  %count_next = add i32 %count, 1
  %done = icmp eq i32 %count_next, 65
  br i1 %done, label %exit, label %loop

exit:
  %logical = lshr i128 %next, 64
  %signed = ashr i128 -1, 127
  %wide_ok = icmp eq i128 %logical, 2
  %signed_ok = icmp eq i128 %signed, -1
  %ok = and i1 %wide_ok, %signed_ok
  %out = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
