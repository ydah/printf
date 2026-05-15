define i32 @main() {
entry:
  %slot = alloca i8, align 1
  store i8 65, ptr %slot, align 1
  %pair = cmpxchg ptr %slot, i8 65, i8 66 seq_cst monotonic, align 1
  %old = extractvalue { i8, i1 } %pair, 0
  %success = extractvalue { i8, i1 } %pair, 1
  %now = load i8, ptr %slot, align 1
  %old_ok = icmp eq i8 %old, 65
  %now_ok = icmp eq i8 %now, 66
  %ok1 = and i1 %old_ok, %success
  %ok = and i1 %ok1, %now_ok
  %out = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
