define i32 @main() {
entry:
  %slot = alloca i8, align 1
  store atomic i8 66, ptr %slot seq_cst, align 1
  fence seq_cst
  %byte = load atomic i8, ptr %slot seq_cst, align 1
  %out = zext i8 %byte to i32
  call i32 @putchar(i32 %out)
  ret i32 0
}
