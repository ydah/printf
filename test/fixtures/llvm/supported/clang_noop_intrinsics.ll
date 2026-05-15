@tag = private unnamed_addr constant [4 x i8] c"tag\00", align 1
@file = private unnamed_addr constant [7 x i8] c"f.c\00\00\00\00", align 1

; common Clang/LLVM marker and query intrinsics
declare i64 @llvm.objectsize.i64.p0(ptr, i1, i1, i1)
declare i1 @llvm.is.constant.i32(i32)
declare i32 @llvm.annotation.i32.p0.p0(i32, ptr, ptr, i32)
declare ptr @llvm.ptr.annotation.p0.p0(ptr, ptr, ptr, i32)
declare ptr @llvm.invariant.start.p0(i64, ptr)
declare void @llvm.invariant.end.p0(ptr, i64, ptr)
declare void @llvm.sideeffect()
declare void @llvm.donothing()

define i32 @main() {
entry:
  %buf = alloca [2 x i8], align 1
  %dst = getelementptr [2 x i8], ptr %buf, i64 0, i64 0
  store i8 66, ptr %dst, align 1
  %tagp = getelementptr [4 x i8], ptr @tag, i64 0, i64 0
  %filep = getelementptr [7 x i8], ptr @file, i64 0, i64 0
  %size = call i64 @llvm.objectsize.i64.p0(ptr %dst, i1 false, i1 true, i1 false)
  %unknown = icmp eq i64 %size, -1
  %constant = call i1 @llvm.is.constant.i32(i32 42)
  %not_constant = icmp eq i1 %constant, false
  %annotated = call i32 @llvm.annotation.i32.p0.p0(i32 66, ptr %tagp, ptr %filep, i32 12)
  %ptr = call ptr @llvm.ptr.annotation.p0.p0(ptr %dst, ptr %tagp, ptr %filep, i32 13)
  %inv = call ptr @llvm.invariant.start.p0(i64 2, ptr %dst)
  call void @llvm.invariant.end.p0(ptr %inv, i64 2, ptr %dst)
  call void @llvm.sideeffect()
  call void @llvm.donothing()
  %byte = load i8, ptr %ptr, align 1
  %wide = zext i8 %byte to i32
  %ann_ok = icmp eq i32 %annotated, 66
  %ok1 = and i1 %unknown, %not_constant
  %ok = and i1 %ok1, %ann_ok
  %out = select i1 %ok, i32 %wide, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
