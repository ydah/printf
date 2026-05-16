@.a = global i8 65, align 1
@.b = global i8 66, align 1

declare i32 @putchar(i32)

define internal i64 @id64(i64 %value) {
entry:
  ret i64 %value
}

define i32 @main() {
entry:
  %encoded = call i64 @id64(i64 ptrtoint (ptr select (i1 icmp eq (ptr @.a, ptr @.a), ptr @.b, ptr @.a) to i64))
  %ptr = inttoptr i64 %encoded to ptr
  %value = load i8, ptr %ptr, align 1
  %wide = zext i8 %value to i32
  call i32 @putchar(i32 %wide)
  ret i32 0
}
