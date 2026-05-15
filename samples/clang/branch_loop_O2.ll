; ModuleID = 'samples/clang/branch_loop.c'
source_filename = "samples/clang/branch_loop.c"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-macosx26.0.0"

; Function Attrs: nofree nounwind ssp uwtable(sync)
define range(i32 0, 2) i32 @main() local_unnamed_addr #0 !dbg !10 {
    #dbg_value(i32 poison, !15, !DIExpression(), !18)
  %1 = tail call i32 @putchar(i32 noundef 66), !dbg !19
  %2 = icmp ne i32 %1, 66, !dbg !22
  %3 = zext i1 %2 to i32, !dbg !19
  ret i32 %3, !dbg !23
}

; Function Attrs: nofree nounwind
declare !dbg !24 noundef i32 @putchar(i32 noundef) local_unnamed_addr #1

attributes #0 = { nofree nounwind ssp uwtable(sync) "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a" }
attributes #1 = { nofree nounwind "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a" }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6}
!llvm.dbg.cu = !{!7}
!llvm.ident = !{!9}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 26, i32 4]}
!1 = !{i32 7, !"Dwarf Version", i32 5}
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !{i32 1, !"wchar_size", i32 4}
!4 = !{i32 8, !"PIC Level", i32 2}
!5 = !{i32 7, !"uwtable", i32 1}
!6 = !{i32 7, !"frame-pointer", i32 1}
!7 = distinct !DICompileUnit(language: DW_LANG_C11, file: !8, producer: "Apple clang version 21.0.0 (clang-2100.0.123.102)", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug, splitDebugInlining: false, nameTableKind: Apple, sysroot: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk", sdk: "MacOSX.sdk")
!8 = !DIFile(filename: "samples/clang/branch_loop.c", directory: "/Users/yudai.takada/ydah/printf", checksumkind: CSK_MD5, checksum: "f5599903a3ae68ebfd30a1926b91ca7a")
!9 = !{!"Apple clang version 21.0.0 (clang-2100.0.123.102)"}
!10 = distinct !DISubprogram(name: "main", scope: !8, file: !8, line: 3, type: !11, scopeLine: 3, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !7, retainedNodes: !14)
!11 = !DISubroutineType(types: !12)
!12 = !{!13}
!13 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!14 = !{!15, !16}
!15 = !DILocalVariable(name: "total", scope: !10, file: !8, line: 4, type: !13)
!16 = !DILocalVariable(name: "i", scope: !17, file: !8, line: 5, type: !13)
!17 = distinct !DILexicalBlock(scope: !10, file: !8, line: 5, column: 3)
!18 = !DILocation(line: 0, scope: !10)
!19 = !DILocation(line: 9, column: 12, scope: !20)
!20 = distinct !DILexicalBlock(scope: !21, file: !8, line: 8, column: 19)
!21 = distinct !DILexicalBlock(scope: !10, file: !8, line: 8, column: 7)
!22 = !DILocation(line: 9, column: 24, scope: !20)
!23 = !DILocation(line: 12, column: 1, scope: !10)
!24 = !DISubprogram(name: "putchar", scope: !8, file: !8, line: 1, type: !25, flags: DIFlagPrototyped, spFlags: DISPFlagOptimized)
!25 = !DISubroutineType(types: !26)
!26 = !{!13, !13}
