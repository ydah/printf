%Item = type { i8, [2 x i8] }
%Packet = type { [2 x %Item], <2 x i8> }

declare void @llvm.lifetime.start(i64, ptr)
declare void @llvm.lifetime.end.p0(i64, ptr)
declare void @llvm.assume(i1)

define i32 @main() {
entry:
  %packet = alloca %Packet, align 1
  call void @llvm.lifetime.start(i64 6, ptr %packet)
  call void @llvm.assume(i1 true) [ "nonnull"(ptr %packet) ]
  %slot = getelementptr %Packet, ptr %packet, i64 0, i32 0, i64 1, i32 1, i64 0
  store i8 66, ptr %slot, align 1
  call void @llvm.lifetime.end.p0(i64 6, ptr %packet)
  %value = load i8, ptr %slot, align 1
  %out = zext i8 %value to i32
  call i32 @putchar(i32 %out)
  ret i32 0
}
