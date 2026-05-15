define i32 @main() {
entry:
  %v0 = insertelement <2 x ptr> zeroinitializer, ptr null, i32 0
  %picked = shufflevector <2 x ptr> %v0, <2 x ptr> zeroinitializer, <1 x i32> <i32 0>
  %ptr = extractelement <1 x ptr> %picked, i32 0
  %ok = icmp eq ptr %ptr, null
  %out = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
