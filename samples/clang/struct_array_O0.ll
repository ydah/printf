; ModuleID = 'samples/clang/struct_array.c'
source_filename = "samples/clang/struct_array.c"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-macosx26.0.0"

%struct.pair = type { i8, i8 }

@__const.main.pairs = private unnamed_addr constant [1 x %struct.pair] [%struct.pair { i8 65, i8 66 }], align 1

; Function Attrs: noinline nounwind optnone ssp uwtable(sync)
define i32 @main() #0 !dbg !12 {
  %1 = alloca i32, align 4
  %2 = alloca [1 x %struct.pair], align 1
  store i32 0, ptr %1, align 4
    #dbg_declare(ptr %2, !15, !DIExpression(), !24)
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %2, ptr align 1 @__const.main.pairs, i64 2, i1 false), !dbg !24
  %3 = getelementptr inbounds [1 x %struct.pair], ptr %2, i64 0, i64 0, !dbg !25
  %4 = getelementptr inbounds nuw %struct.pair, ptr %3, i32 0, i32 1, !dbg !26
  %5 = load i8, ptr %4, align 1, !dbg !26
  %6 = zext i8 %5 to i32, !dbg !27
  %7 = call i32 @putchar(i32 noundef %6), !dbg !28
  %8 = icmp eq i32 %7, 66, !dbg !29
  %9 = zext i1 %8 to i64, !dbg !28
  %10 = select i1 %8, i32 0, i32 1, !dbg !28
  ret i32 %10, !dbg !30
}

; Function Attrs: nocallback nofree nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

declare i32 @putchar(i32 noundef) #2

attributes #0 = { noinline nounwind optnone ssp uwtable(sync) "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a" }
attributes #1 = { nocallback nofree nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a" }

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
!8 = !DIFile(filename: "samples/clang/struct_array.c", directory: "/Users/yudai.takada/ydah/printf", checksumkind: CSK_MD5, checksum: "57b62160443a727e7c14ca22da5c6b06")
!9 = !{!10}
!10 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!11 = !{!"Apple clang version 21.0.0 (clang-2100.0.123.102)"}
!12 = distinct !DISubprogram(name: "main", scope: !8, file: !8, line: 8, type: !13, scopeLine: 8, flags: DIFlagPrototyped, spFlags: DISPFlagDefinition, unit: !7, retainedNodes: !14)
!13 = !DISubroutineType(types: !9)
!14 = !{}
!15 = !DILocalVariable(name: "pairs", scope: !12, file: !8, line: 9, type: !16)
!16 = !DICompositeType(tag: DW_TAG_array_type, baseType: !17, size: 16, elements: !22)
!17 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "pair", file: !8, line: 3, size: 16, elements: !18)
!18 = !{!19, !21}
!19 = !DIDerivedType(tag: DW_TAG_member, name: "first", scope: !17, file: !8, line: 4, baseType: !20, size: 8)
!20 = !DIBasicType(name: "unsigned char", size: 8, encoding: DW_ATE_unsigned_char)
!21 = !DIDerivedType(tag: DW_TAG_member, name: "second", scope: !17, file: !8, line: 5, baseType: !20, size: 8, offset: 8)
!22 = !{!23}
!23 = !DISubrange(count: 1)
!24 = !DILocation(line: 9, column: 15, scope: !12)
!25 = !DILocation(line: 10, column: 23, scope: !12)
!26 = !DILocation(line: 10, column: 32, scope: !12)
!27 = !DILocation(line: 10, column: 18, scope: !12)
!28 = !DILocation(line: 10, column: 10, scope: !12)
!29 = !DILocation(line: 10, column: 40, scope: !12)
!30 = !DILocation(line: 10, column: 3, scope: !12)
