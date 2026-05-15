; ModuleID = 'samples/clang/branch_loop.c'
source_filename = "samples/clang/branch_loop.c"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-macosx26.0.0"

; Function Attrs: noinline nounwind optnone ssp uwtable(sync)
define i32 @main() #0 !dbg !10 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  store i32 0, ptr %1, align 4
    #dbg_declare(ptr %2, !15, !DIExpression(), !16)
  store i32 0, ptr %2, align 4, !dbg !16
    #dbg_declare(ptr %3, !17, !DIExpression(), !19)
  store i32 0, ptr %3, align 4, !dbg !19
  br label %4, !dbg !20

4:                                                ; preds = %11, %0
  %5 = load i32, ptr %3, align 4, !dbg !21
  %6 = icmp slt i32 %5, 3, !dbg !23
  br i1 %6, label %7, label %14, !dbg !24

7:                                                ; preds = %4
  %8 = load i32, ptr %3, align 4, !dbg !25
  %9 = load i32, ptr %2, align 4, !dbg !27
  %10 = add nsw i32 %9, %8, !dbg !27
  store i32 %10, ptr %2, align 4, !dbg !27
  br label %11, !dbg !28

11:                                               ; preds = %7
  %12 = load i32, ptr %3, align 4, !dbg !29
  %13 = add nsw i32 %12, 1, !dbg !29
  store i32 %13, ptr %3, align 4, !dbg !29
  br label %4, !dbg !30, !llvm.loop !31

14:                                               ; preds = %4
  %15 = load i32, ptr %2, align 4, !dbg !34
  %16 = icmp eq i32 %15, 3, !dbg !36
  br i1 %16, label %17, label %22, !dbg !36

17:                                               ; preds = %14
  %18 = call i32 @putchar(i32 noundef 66), !dbg !37
  %19 = icmp eq i32 %18, 66, !dbg !39
  %20 = zext i1 %19 to i64, !dbg !37
  %21 = select i1 %19, i32 0, i32 1, !dbg !37
  store i32 %21, ptr %1, align 4, !dbg !40
  br label %27, !dbg !40

22:                                               ; preds = %14
  %23 = call i32 @putchar(i32 noundef 78), !dbg !41
  %24 = icmp eq i32 %23, 78, !dbg !42
  %25 = zext i1 %24 to i64, !dbg !41
  %26 = select i1 %24, i32 1, i32 2, !dbg !41
  store i32 %26, ptr %1, align 4, !dbg !43
  br label %27, !dbg !43

27:                                               ; preds = %22, %17
  %28 = load i32, ptr %1, align 4, !dbg !44
  ret i32 %28, !dbg !44
}

declare i32 @putchar(i32 noundef) #1

attributes #0 = { noinline nounwind optnone ssp uwtable(sync) "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a" }
attributes #1 = { "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a" }

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
!7 = distinct !DICompileUnit(language: DW_LANG_C11, file: !8, producer: "Apple clang version 21.0.0 (clang-2100.0.123.102)", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, splitDebugInlining: false, nameTableKind: Apple, sysroot: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk", sdk: "MacOSX.sdk")
!8 = !DIFile(filename: "samples/clang/branch_loop.c", directory: "/Users/yudai.takada/ydah/printf", checksumkind: CSK_MD5, checksum: "f5599903a3ae68ebfd30a1926b91ca7a")
!9 = !{!"Apple clang version 21.0.0 (clang-2100.0.123.102)"}
!10 = distinct !DISubprogram(name: "main", scope: !8, file: !8, line: 3, type: !11, scopeLine: 3, flags: DIFlagPrototyped, spFlags: DISPFlagDefinition, unit: !7, retainedNodes: !14)
!11 = !DISubroutineType(types: !12)
!12 = !{!13}
!13 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!14 = !{}
!15 = !DILocalVariable(name: "total", scope: !10, file: !8, line: 4, type: !13)
!16 = !DILocation(line: 4, column: 7, scope: !10)
!17 = !DILocalVariable(name: "i", scope: !18, file: !8, line: 5, type: !13)
!18 = distinct !DILexicalBlock(scope: !10, file: !8, line: 5, column: 3)
!19 = !DILocation(line: 5, column: 12, scope: !18)
!20 = !DILocation(line: 5, column: 8, scope: !18)
!21 = !DILocation(line: 5, column: 19, scope: !22)
!22 = distinct !DILexicalBlock(scope: !18, file: !8, line: 5, column: 3)
!23 = !DILocation(line: 5, column: 21, scope: !22)
!24 = !DILocation(line: 5, column: 3, scope: !18)
!25 = !DILocation(line: 6, column: 14, scope: !26)
!26 = distinct !DILexicalBlock(scope: !22, file: !8, line: 5, column: 31)
!27 = !DILocation(line: 6, column: 11, scope: !26)
!28 = !DILocation(line: 7, column: 3, scope: !26)
!29 = !DILocation(line: 5, column: 27, scope: !22)
!30 = !DILocation(line: 5, column: 3, scope: !22)
!31 = distinct !{!31, !24, !32, !33}
!32 = !DILocation(line: 7, column: 3, scope: !18)
!33 = !{!"llvm.loop.mustprogress"}
!34 = !DILocation(line: 8, column: 7, scope: !35)
!35 = distinct !DILexicalBlock(scope: !10, file: !8, line: 8, column: 7)
!36 = !DILocation(line: 8, column: 13, scope: !35)
!37 = !DILocation(line: 9, column: 12, scope: !38)
!38 = distinct !DILexicalBlock(scope: !35, file: !8, line: 8, column: 19)
!39 = !DILocation(line: 9, column: 24, scope: !38)
!40 = !DILocation(line: 9, column: 5, scope: !38)
!41 = !DILocation(line: 11, column: 10, scope: !10)
!42 = !DILocation(line: 11, column: 22, scope: !10)
!43 = !DILocation(line: 11, column: 3, scope: !10)
!44 = !DILocation(line: 12, column: 1, scope: !10)
