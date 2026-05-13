declare i32 @putchar(i32)

define i32 @main() {
entry:
  %mul = mul i32 9, 8
  %udiv = udiv i32 %mul, 2
  %urem = urem i32 %mul, 5
  %and = and i32 %udiv, 63
  %or = or i32 %and, 64
  %xor = xor i32 %or, 38
  %shl = shl i32 1, 6
  %lshr = lshr i32 %shl, 1
  %sdiv = sdiv i32 132, 2
  %srem = srem i32 67, 1
  %ashr = ashr i8 240, 1
  %cmp = icmp eq i32 %lshr, 32
  %selected = select i1 %cmp, i32 %xor, i32 %sdiv
  call i32 @putchar(i32 %selected)
  ret i32 %srem
}
