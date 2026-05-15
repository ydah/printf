declare i8 @llvm.uadd.sat.i8(i8, i8)
declare i8 @llvm.ssub.sat.i8(i8, i8)
declare i8 @llvm.fshl.i8(i8, i8, i8)
declare i8 @llvm.bitreverse.i8(i8)
declare i8 @llvm.vector.reduce.add.v2i8(<2 x i8>)

define i32 @main() {
entry:
  %uadd = call i8 @llvm.uadd.sat.i8(i8 250, i8 10)
  %uadd_ok = icmp eq i8 %uadd, 255
  %ssub = call i8 @llvm.ssub.sat.i8(i8 -120, i8 20)
  %ssub_ok = icmp eq i8 %ssub, 128
  %fshl = call i8 @llvm.fshl.i8(i8 16, i8 2, i8 2)
  %fshl_ok = icmp eq i8 %fshl, 64
  %rev = call i8 @llvm.bitreverse.i8(i8 66)
  %rev_ok = icmp eq i8 %rev, 66
  %sum = call i8 @llvm.vector.reduce.add.v2i8(<2 x i8> <i8 40, i8 26>)
  %sum_ok = icmp eq i8 %sum, 66
  %ok1 = and i1 %uadd_ok, %ssub_ok
  %ok2 = and i1 %fshl_ok, %rev_ok
  %ok3 = and i1 %ok1, %ok2
  %ok = and i1 %ok3, %sum_ok
  %out = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
