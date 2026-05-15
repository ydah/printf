; ModuleID = 'samples/clang/struct_array.c'
source_filename = "samples/clang/struct_array.c"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-macosx26.0.0"

; Function Attrs: nofree nounwind ssp uwtable(sync)
define range(i32 0, 2) i32 @main() local_unnamed_addr #0 !dbg !12 {
    #dbg_value(i8 poison, !15, !DIExpression(DW_OP_LLVM_fragment, 0, 8), !24)
    #dbg_value(i8 66, !15, !DIExpression(DW_OP_LLVM_fragment, 8, 8), !24)
  %1 = tail call i32 @putchar(i32 noundef 66), !dbg !25
  %2 = icmp ne i32 %1, 66, !dbg !26
  %3 = zext i1 %2 to i32, !dbg !25
  ret i32 %3, !dbg !27
}

; Function Attrs: nofree nounwind
declare !dbg !28 noundef i32 @putchar(i32 noundef) local_unnamed_addr #1

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
!8 = !DIFile(filename: "samples/clang/struct_array.c", directory: "/Users/yudai.takada/ydah/printf", checksumkind: CSK_MD5, checksum: "57b62160443a727e7c14ca22da5c6b06")
!9 = !{!10}
!10 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!11 = !{!"Apple clang version 21.0.0 (clang-2100.0.123.102)"}
!12 = distinct !DISubprogram(name: "main", scope: !8, file: !8, line: 8, type: !13, scopeLine: 8, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !7, retainedNodes: !14)
!13 = !DISubroutineType(types: !9)
!14 = !{!15}
!15 = !DILocalVariable(name: "pairs", scope: !12, file: !8, line: 9, type: !16)
!16 = !DICompositeType(tag: DW_TAG_array_type, baseType: !17, size: 16, elements: !22)
!17 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "pair", file: !8, line: 3, size: 16, elements: !18)
!18 = !{!19, !21}
!19 = !DIDerivedType(tag: DW_TAG_member, name: "first", scope: !17, file: !8, line: 4, baseType: !20, size: 8)
!20 = !DIBasicType(name: "unsigned char", size: 8, encoding: DW_ATE_unsigned_char)
!21 = !DIDerivedType(tag: DW_TAG_member, name: "second", scope: !17, file: !8, line: 5, baseType: !20, size: 8, offset: 8)
!22 = !{!23}
!23 = !DISubrange(count: 1)
!24 = !DILocation(line: 0, scope: !12)
!25 = !DILocation(line: 10, column: 10, scope: !12)
!26 = !DILocation(line: 10, column: 40, scope: !12)
!27 = !DILocation(line: 10, column: 3, scope: !12)
!28 = !DISubprogram(name: "putchar", scope: !8, file: !8, line: 1, type: !29, flags: DIFlagPrototyped, spFlags: DISPFlagOptimized)
!29 = !DISubroutineType(types: !30)
!30 = !{!10, !10}
