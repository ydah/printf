%struct.Pair = type { i8, i8 }

@.str = private unnamed_addr constant [2 x i8] c"B\00"

declare i32 @putchar(i32)
declare void @llvm.assume(i1)
declare i1 @llvm.expect.i1(i1, i1)
declare void @llvm.dbg.value(metadata, metadata, metadata)

define i32 @main() {
entry:
  %pair = alloca %struct.Pair, align 1
  %field = getelementptr %struct.Pair, ptr %pair, i32 0, i32 1
  %from_string = getelementptr [2 x i8], ptr @.str, i32 0, i32 0
  %value = load i8, ptr %from_string, align 1
  store i8 %value, ptr %field, align 1
  call void @llvm.dbg.value(metadata i8 %value, metadata !1, metadata !DIExpression())
  %ok = call i1 @llvm.expect.i1(i1 true, i1 true)
  call void @llvm.assume(i1 %ok)
  br i1 %ok, label %then, label %else

then:
  br label %join

else:
  br label %join

join:
  %selected = phi ptr [ %field, %then ], [ %from_string, %else ]
  %out = load i8, ptr %selected, align 1
  %extended = zext i8 %out to i32
  call i32 @putchar(i32 %extended)
  ret i32 0
}
