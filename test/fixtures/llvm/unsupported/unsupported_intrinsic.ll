declare i32 @llvm.experimental.unsupported.i32(i32)

define i32 @main() {
entry:
  %x = call i32 @llvm.experimental.unsupported.i32(i32 1)
  ret i32 %x
}
