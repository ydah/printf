declare void @opaque(ptr)

define i32 @main() {
entry:
  %p = alloca i8, align 1
  call void @opaque(ptr %p)
  ret i32 0
}
