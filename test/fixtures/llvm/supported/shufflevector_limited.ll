define i32 @main() {
entry:
  %concat = shufflevector <2 x i8> <i8 65, i8 66>, <2 x i8> <i8 67, i8 68>, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %splat = shufflevector <4 x i8> %concat, <4 x i8> zeroinitializer, <2 x i32> <i32 1, i32 1>
  %byte = extractelement <2 x i8> %splat, i32 0
  %out = zext i8 %byte to i32
  call i32 @putchar(i32 %out)
  ret i32 0
}
