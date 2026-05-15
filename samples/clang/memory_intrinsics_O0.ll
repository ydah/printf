; ModuleID = 'samples/clang/memory_intrinsics.c'
source_filename = "samples/clang/memory_intrinsics.c"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-macosx26.0.0"

@__const.main.source = private unnamed_addr constant [4 x i8] c"AB\00\00", align 1

; Function Attrs: noinline nounwind optnone ssp uwtable(sync)
define i32 @main() #0 !dbg !12 {
  %1 = alloca i32, align 4
  %2 = alloca [4 x i8], align 1
  %3 = alloca [4 x i8], align 1
  store i32 0, ptr %1, align 4
    #dbg_declare(ptr %2, !15, !DIExpression(), !20)
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %2, ptr align 1 @__const.main.source, i64 4, i1 false), !dbg !20
    #dbg_declare(ptr %3, !21, !DIExpression(), !22)
  %4 = getelementptr inbounds [4 x i8], ptr %3, i64 0, i64 0, !dbg !23
  call void @llvm.memset.p0.i64(ptr align 1 %4, i8 0, i64 4, i1 false), !dbg !23
  %5 = getelementptr inbounds [4 x i8], ptr %3, i64 0, i64 0, !dbg !24
  %6 = getelementptr inbounds [4 x i8], ptr %2, i64 0, i64 0, !dbg !24
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %5, ptr align 1 %6, i64 2, i1 false), !dbg !24
  %7 = getelementptr inbounds [4 x i8], ptr %3, i64 0, i64 1, !dbg !25
  %8 = load i8, ptr %7, align 1, !dbg !25
  %9 = zext i8 %8 to i32, !dbg !26
  %10 = call i32 @putchar(i32 noundef %9), !dbg !27
  %11 = icmp eq i32 %10, 66, !dbg !28
  %12 = zext i1 %11 to i64, !dbg !27
  %13 = select i1 %11, i32 0, i32 1, !dbg !27
  ret i32 %13, !dbg !29
}

; Function Attrs: nocallback nofree nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: nocallback nofree nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #2

declare i32 @putchar(i32 noundef) #3

attributes #0 = { noinline nounwind optnone ssp uwtable(sync) "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a" }
attributes #1 = { nocallback nofree nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nofree nounwind willreturn memory(argmem: write) }
attributes #3 = { "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a" }

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
!8 = !DIFile(filename: "samples/clang/memory_intrinsics.c", directory: "/Users/yudai.takada/ydah/printf", checksumkind: CSK_MD5, checksum: "593852a9b0f16771f34ad32517396888")
!9 = !{!10}
!10 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!11 = !{!"Apple clang version 21.0.0 (clang-2100.0.123.102)"}
!12 = distinct !DISubprogram(name: "main", scope: !8, file: !8, line: 3, type: !13, scopeLine: 3, flags: DIFlagPrototyped, spFlags: DISPFlagDefinition, unit: !7, retainedNodes: !14)
!13 = !DISubroutineType(types: !9)
!14 = !{}
!15 = !DILocalVariable(name: "source", scope: !12, file: !8, line: 4, type: !16)
!16 = !DICompositeType(tag: DW_TAG_array_type, baseType: !17, size: 32, elements: !18)
!17 = !DIBasicType(name: "unsigned char", size: 8, encoding: DW_ATE_unsigned_char)
!18 = !{!19}
!19 = !DISubrange(count: 4)
!20 = !DILocation(line: 4, column: 17, scope: !12)
!21 = !DILocalVariable(name: "target", scope: !12, file: !8, line: 5, type: !16)
!22 = !DILocation(line: 5, column: 17, scope: !12)
!23 = !DILocation(line: 6, column: 3, scope: !12)
!24 = !DILocation(line: 7, column: 3, scope: !12)
!25 = !DILocation(line: 8, column: 23, scope: !12)
!26 = !DILocation(line: 8, column: 18, scope: !12)
!27 = !DILocation(line: 8, column: 10, scope: !12)
!28 = !DILocation(line: 8, column: 34, scope: !12)
!29 = !DILocation(line: 8, column: 3, scope: !12)
