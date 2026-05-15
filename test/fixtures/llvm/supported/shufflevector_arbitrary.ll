define i32 @main() {
entry:
  %shuffle = shufflevector <2 x i8> <i8 65, i8 66>, <2 x i8> <i8 67, i8 68>, <3 x i32> <i32 1, i32 2, i32 0>
  %byte = extractelement <3 x i8> %shuffle, i32 0
  %out = zext i8 %byte to i32
  call i32 @putchar(i32 %out)
  ret i32 0
}
