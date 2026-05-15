declare { i8, i1 } @llvm.uadd.with.overflow.i8(i8, i8)
declare { i8, i1 } @llvm.usub.with.overflow.i8(i8, i8)
declare { i8, i1 } @llvm.smul.with.overflow.i8(i8, i8)
declare { i16, i1 } @llvm.sadd.with.overflow.i16(i16, i16)

define i32 @main() {
entry:
  %uadd = call { i8, i1 } @llvm.uadd.with.overflow.i8(i8 255, i8 1)
  %uadd_value = extractvalue { i8, i1 } %uadd, 0
  %uadd_overflow = extractvalue { i8, i1 } %uadd, 1
  %uadd_wrapped = icmp eq i8 %uadd_value, 0
  %usub = call { i8, i1 } @llvm.usub.with.overflow.i8(i8 0, i8 1)
  %usub_value = extractvalue { i8, i1 } %usub, 0
  %usub_overflow = extractvalue { i8, i1 } %usub, 1
  %usub_wrapped = icmp eq i8 %usub_value, 255
  %smul = call { i8, i1 } @llvm.smul.with.overflow.i8(i8 64, i8 2)
  %smul_overflow = extractvalue { i8, i1 } %smul, 1
  %sadd = call { i16, i1 } @llvm.sadd.with.overflow.i16(i16 40, i16 2)
  %sadd_value = extractvalue { i16, i1 } %sadd, 0
  %sadd_overflow = extractvalue { i16, i1 } %sadd, 1
  %sadd_value_ok = icmp eq i16 %sadd_value, 42
  %sadd_no_overflow = icmp eq i1 %sadd_overflow, false
  %ok1 = and i1 %uadd_overflow, %uadd_wrapped
  %ok2 = and i1 %usub_overflow, %usub_wrapped
  %ok3 = and i1 %smul_overflow, %sadd_value_ok
  %ok4 = and i1 %ok1, %ok2
  %ok5 = and i1 %ok3, %sadd_no_overflow
  %ok = and i1 %ok4, %ok5
  %out = select i1 %ok, i32 66, i32 78
  call i32 @putchar(i32 %out)
  ret i32 0
}
