declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
declare i32 @putchar(i32)

define i32 @main() {
entry:
  %src = alloca [2 x i8], align 1
  %dst = alloca [2 x i8], align 1
  %src1 = getelementptr [2 x i8], ptr %src, i64 0, i64 1
  store i8 66, ptr %src1, align 1
  call void @llvm.memcpy.p0.p0.i64(ptr nonnull align 1 %dst, ptr readonly captures(none) %src, i64 noundef 2, i1 immarg false)
  %dst1 = getelementptr [2 x i8], ptr %dst, i64 0, i64 1
  %value = load i8, ptr %dst1, align 1
  %wide = zext i8 %value to i32
  call i32 @putchar(i32 %wide)
  ret i32 0
}
