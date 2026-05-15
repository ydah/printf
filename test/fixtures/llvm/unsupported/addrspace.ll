define i32 @main(ptr addrspace(1) %p) {
entry:
  %casted = addrspacecast ptr addrspace(1) %p to ptr
  ret i32 0
}
