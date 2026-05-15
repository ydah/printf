; ModuleID = 'samples/clang/internal_call.c'
source_filename = "samples/clang/internal_call.c"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-macosx26.0.0"

; Function Attrs: noinline nounwind optnone ssp uwtable(sync)
define i32 @main() #0 !dbg !12 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = call zeroext i8 @pick(), !dbg !14
  %3 = zext i8 %2 to i32, !dbg !15
  %4 = call i32 @putchar(i32 noundef %3), !dbg !16
  %5 = icmp eq i32 %4, 66, !dbg !17
  %6 = zext i1 %5 to i64, !dbg !16
  %7 = select i1 %5, i32 0, i32 1, !dbg !16
  ret i32 %7, !dbg !18
}

declare i32 @putchar(i32 noundef) #1

; Function Attrs: noinline nounwind optnone ssp uwtable(sync)
define internal zeroext i8 @pick() #0 !dbg !19 {
  ret i8 66, !dbg !23
}

attributes #0 = { noinline nounwind optnone ssp uwtable(sync) "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a" }
attributes #1 = { "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a" }

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
!7 = distinct !DICompileUnit(language: DW_LANG_C11, file: !8, producer: "Apple clang version 21.0.0 (clang-2100.0.123.102)", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, retainedTypes: !9, splitDebugInlining: false, nameTableKind: Apple, sysroot: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk", sdk: "MacOSX.sdk")
!8 = !DIFile(filename: "samples/clang/internal_call.c", directory: "/Users/yudai.takada/ydah/printf", checksumkind: CSK_MD5, checksum: "4c466d6ce50bd29e86d7d8c385952c3a")
!9 = !{!10}
!10 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!11 = !{!"Apple clang version 21.0.0 (clang-2100.0.123.102)"}
!12 = distinct !DISubprogram(name: "main", scope: !8, file: !8, line: 7, type: !13, scopeLine: 7, flags: DIFlagPrototyped, spFlags: DISPFlagDefinition, unit: !7)
!13 = !DISubroutineType(types: !9)
!14 = !DILocation(line: 8, column: 23, scope: !12)
!15 = !DILocation(line: 8, column: 18, scope: !12)
!16 = !DILocation(line: 8, column: 10, scope: !12)
!17 = !DILocation(line: 8, column: 31, scope: !12)
!18 = !DILocation(line: 8, column: 3, scope: !12)
!19 = distinct !DISubprogram(name: "pick", scope: !8, file: !8, line: 3, type: !20, scopeLine: 3, flags: DIFlagPrototyped, spFlags: DISPFlagLocalToUnit | DISPFlagDefinition, unit: !7)
!20 = !DISubroutineType(types: !21)
!21 = !{!22}
!22 = !DIBasicType(name: "unsigned char", size: 8, encoding: DW_ATE_unsigned_char)
!23 = !DILocation(line: 4, column: 3, scope: !19)
