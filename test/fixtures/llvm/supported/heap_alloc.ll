declare ptr @malloc(i64)
declare ptr @calloc(i64, i64)
declare void @free(ptr)

define i32 @main() {
entry:
  %mem = call ptr @malloc(i64 2)
  store i8 66, ptr %mem, align 1
  %zero = call ptr @calloc(i64 1, i64 1)
  %z = load i8, ptr %zero, align 1
  %z_ok = icmp eq i8 %z, 0
  %byte = load i8, ptr %mem, align 1
  call void @free(ptr %mem)
  call void @free(ptr %zero)
  %wide = zext i8 %byte to i32
  %out = select i1 %z_ok, i32 %wide, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
