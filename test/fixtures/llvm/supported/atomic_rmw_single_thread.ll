define i32 @main() {
entry:
  %slot = alloca i8, align 1
  store i8 65, ptr %slot, align 1
  %old = atomicrmw add ptr %slot, i8 1 seq_cst, align 1
  %now = load i8, ptr %slot, align 1
  %old_ok = icmp eq i8 %old, 65
  %now_ok = icmp eq i8 %now, 66
  %ok = and i1 %old_ok, %now_ok
  %out = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
