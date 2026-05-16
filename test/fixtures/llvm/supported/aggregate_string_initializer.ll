%struct.Payload = type { [3 x i8], i8 }
@.payload = global %struct.Payload { [3 x i8] c"AB\00", i8 78 }, align 1

declare i32 @putchar(i32)

define i32 @main() {
entry:
  %second = getelementptr %struct.Payload, ptr @.payload, i64 0, i32 0, i64 1
  %value = load i8, ptr %second, align 1
  %wide = zext i8 %value to i32
  call i32 @putchar(i32 %wide)
  ret i32 0
}
