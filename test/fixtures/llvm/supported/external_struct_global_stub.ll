%struct.Pair = type { i8, i8 }
@external_pair = external global %struct.Pair, align 1

declare i32 @putchar(i32)

define i32 @main() {
entry:
  %second = getelementptr %struct.Pair, ptr @external_pair, i64 0, i32 1
  store i8 66, ptr %second, align 1
  %value = load i8, ptr %second, align 1
  %wide = zext i8 %value to i32
  call i32 @putchar(i32 %wide)
  ret i32 0
}
