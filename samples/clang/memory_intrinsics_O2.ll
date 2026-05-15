; ModuleID = 'samples/clang/memory_intrinsics.c'
source_filename = "samples/clang/memory_intrinsics.c"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-macosx26.0.0"

; Function Attrs: nofree nounwind ssp uwtable(sync)
define range(i32 0, 2) i32 @main() local_unnamed_addr #0 !dbg !12 {
    #dbg_declare(ptr poison, !15, !DIExpression(DW_OP_LLVM_fragment, 16, 16), !21)
    #dbg_value(i8 poison, !15, !DIExpression(DW_OP_LLVM_fragment, 0, 8), !22)
    #dbg_value(i8 66, !15, !DIExpression(DW_OP_LLVM_fragment, 8, 8), !22)
    #dbg_value(i8 0, !20, !DIExpression(DW_OP_LLVM_fragment, 0, 8), !22)
    #dbg_value(i8 0, !20, !DIExpression(DW_OP_LLVM_fragment, 8, 8), !22)
    #dbg_value(i8 poison, !20, !DIExpression(DW_OP_LLVM_fragment, 0, 8), !22)
    #dbg_value(i8 66, !20, !DIExpression(DW_OP_LLVM_fragment, 8, 8), !22)
  %1 = tail call i32 @putchar(i32 noundef 66), !dbg !23
  %2 = icmp ne i32 %1, 66, !dbg !24
  %3 = zext i1 %2 to i32, !dbg !23
  ret i32 %3, !dbg !25
}

; Function Attrs: nofree nounwind
declare !dbg !26 noundef i32 @putchar(i32 noundef) local_unnamed_addr #1

attributes #0 = { nofree nounwind ssp uwtable(sync) "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a" }
attributes #1 = { nofree nounwind "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a" }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6}
!llvm.dbg.cu = !{!7}
!llvm.ident = !{!11}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 26, i32 4]}
!1 = !{i32 7, !"Dwarf Version", i32 5}
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !{i32 1, !"wchar_size", i32 4}
!4 = !{i32 8, !"PIC Level", i32 2}
!5 = !{i32 7, !"uwtable", i32 1}
!6 = !{i32 7, !"frame-pointer", i32 1}
!7 = distinct !DICompileUnit(language: DW_LANG_C11, file: !8, producer: "Apple clang version 21.0.0 (clang-2100.0.123.102)", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug, retainedTypes: !9, splitDebugInlining: false, nameTableKind: Apple, sysroot: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk", sdk: "MacOSX.sdk")
!8 = !DIFile(filename: "samples/clang/memory_intrinsics.c", directory: "/Users/yudai.takada/ydah/printf", checksumkind: CSK_MD5, checksum: "593852a9b0f16771f34ad32517396888")
!9 = !{!10}
!10 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!11 = !{!"Apple clang version 21.0.0 (clang-2100.0.123.102)"}
!12 = distinct !DISubprogram(name: "main", scope: !8, file: !8, line: 3, type: !13, scopeLine: 3, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !7, retainedNodes: !14)
!13 = !DISubroutineType(types: !9)
!14 = !{!15, !20}
!15 = !DILocalVariable(name: "source", scope: !12, file: !8, line: 4, type: !16)
!16 = !DICompositeType(tag: DW_TAG_array_type, baseType: !17, size: 32, elements: !18)
!17 = !DIBasicType(name: "unsigned char", size: 8, encoding: DW_ATE_unsigned_char)
!18 = !{!19}
!19 = !DISubrange(count: 4)
!20 = !DILocalVariable(name: "target", scope: !12, file: !8, line: 5, type: !16)
!21 = !DILocation(line: 4, column: 17, scope: !12)
!22 = !DILocation(line: 0, scope: !12)
!23 = !DILocation(line: 8, column: 10, scope: !12)
!24 = !DILocation(line: 8, column: 34, scope: !12)
!25 = !DILocation(line: 8, column: 3, scope: !12)
!26 = !DISubprogram(name: "putchar", scope: !8, file: !8, line: 1, type: !27, flags: DIFlagPrototyped, spFlags: DISPFlagOptimized)
!27 = !DISubroutineType(types: !28)
!28 = !{!10, !10}
