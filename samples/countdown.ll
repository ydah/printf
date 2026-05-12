declare i32 @putchar(i32)

define i32 @main() {
entry:
  %counter = alloca i8, align 1
  store i8 3, ptr %counter, align 1
  br label %loop

loop:
  %value = load i8, ptr %counter, align 1
  %more = icmp ne i8 %value, 0
  br i1 %more, label %body, label %exit

body:
  call i32 @putchar(i32 88)
  %old = load i8, ptr %counter, align 1
  %next = sub i8 %old, 1
  store i8 %next, ptr %counter, align 1
  br label %loop

exit:
  ret i32 0
}
