declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
declare void @llvm.memmove.p0.p0.i64(ptr, ptr, i64, i1)
declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)
declare i32 @putchar(i32)

define internal <2 x i8> @copy_vector(<2 x i8> %value) {
entry:
  %src = alloca <2 x i8>, align 2
  %dst = alloca <2 x i8>, align 2
  store <2 x i8> %value, ptr %src, align 2
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %src, i64 2, i1 false)
  %loaded = load <2 x i8>, ptr %dst, align 2
  ret <2 x i8> %loaded
}

define internal <2 x i8> @set_vector() {
entry:
  %dst = alloca <2 x i8>, align 2
  call void @llvm.memset.p0.i64(ptr %dst, i8 66, i64 2, i1 false)
  %loaded = load <2 x i8>, ptr %dst, align 2
  ret <2 x i8> %loaded
}

define internal <2 x i8> @move_vector(<2 x i8> %value) {
entry:
  %src = alloca <2 x i8>, align 2
  %dst = alloca <2 x i8>, align 2
  store <2 x i8> %value, ptr %src, align 2
  call void @llvm.memmove.p0.p0.i64(ptr %dst, ptr %src, i64 2, i1 false)
  %loaded = load <2 x i8>, ptr %dst, align 2
  ret <2 x i8> %loaded
}

define i32 @main() {
entry:
  %copied = call <2 x i8> @copy_vector(<2 x i8> <i8 65, i8 66>)
  %set = call <2 x i8> @set_vector()
  %moved = call <2 x i8> @move_vector(<2 x i8> %copied)
  %a = extractelement <2 x i8> %set, i32 0
  %b = extractelement <2 x i8> %moved, i32 1
  %a32 = zext i8 %a to i32
  %b32 = zext i8 %b to i32
  %a_ok = icmp eq i32 %a32, 66
  %b_ok = icmp eq i32 %b32, 66
  %ok = and i1 %a_ok, %b_ok
  %out = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
