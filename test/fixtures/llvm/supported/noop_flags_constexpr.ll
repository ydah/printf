define i32 @main() {
entry:
  %sum = add nuw nsw i32 40, 2
  %flagged = or disjoint i32 %sum, 0
  %ok = icmp eq i32 %flagged, 42
  call i32 @putchar(i32 select (i1 %ok, i32 66, i32 78))
  ret i32 0
}
