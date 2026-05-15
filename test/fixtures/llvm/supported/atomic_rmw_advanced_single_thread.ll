define i32 @main() {
entry:
  %slot = alloca i8, align 1
  store i8 2, ptr %slot, align 1
  %inc_old = atomicrmw uinc_wrap ptr %slot, i8 2 seq_cst, align 1
  %after_inc = load i8, ptr %slot, align 1
  %dec_old = atomicrmw udec_wrap ptr %slot, i8 2 seq_cst, align 1
  %cond_old = atomicrmw usub_cond ptr %slot, i8 3 seq_cst, align 1
  %sat_old = atomicrmw usub_sat ptr %slot, i8 3 seq_cst, align 1
  %after_sat = load i8, ptr %slot, align 1
  %ok1 = icmp eq i8 %inc_old, 2
  %ok2 = icmp eq i8 %after_inc, 0
  %ok3 = icmp eq i8 %dec_old, 0
  %ok4 = icmp eq i8 %cond_old, 2
  %ok5 = icmp eq i8 %sat_old, 2
  %ok6 = icmp eq i8 %after_sat, 0
  %a = and i1 %ok1, %ok2
  %b = and i1 %ok3, %ok4
  %c = and i1 %ok5, %ok6
  %d = and i1 %a, %b
  %ok = and i1 %d, %c
  %out = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
