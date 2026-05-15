; ModuleID = 'clang_attrs_intrinsics_smoke.c'
source_filename = "clang_attrs_intrinsics_smoke.c"
target datalayout = "e-m:o-i64:64-n32:64-S128"
target triple = "arm64-apple-macosx15.0.0"

@.bytes = internal global [2 x i8] [i8 65, i8 66], align 1
@.selected = internal global ptr getelementptr inbounds ([2 x i8], ptr @.bytes, i64 0, i64 1), align 8

declare noundef i32 @putchar(i32 noundef) #1
declare i32 @llvm.smax.i32(i32, i32) #1
declare i32 @llvm.abs.i32(i32, i1) #1
declare void @llvm.dbg.value(metadata, metadata, metadata) #1

define noundef i32 @main() #0 {
entry:
  %ptr = load ptr, ptr @.selected, align 8, !tbaa !10
  %byte = load i8, ptr nonnull dereferenceable(1) %ptr, align 1, !alias.scope !11, !noalias !12
  %wide = zext i8 %byte to i32
  %frozen = freeze i32 %wide
  %max = call noundef i32 @llvm.smax.i32(i32 noundef %frozen, i32 noundef 65), !range !13
  %abs = call i32 @llvm.abs.i32(i32 -66, i1 true)
  %same = icmp eq i32 %max, %abs
  %out = select i1 %same, i32 %max, i32 78
  call void @llvm.dbg.value(metadata i32 %out, metadata !14, metadata !DIExpression()), !dbg !15
  call i32 @putchar(i32 %out)
  ret i32 0
}

attributes #0 = { noinline nounwind optnone uwtable "frame-pointer"="non-leaf" }
attributes #1 = { nounwind }

!llvm.module.flags = !{!0}
!llvm.ident = !{!1}
!0 = !{i32 2, !"Debug Info Version", i32 3}
!1 = !{!"clang version 18.1.8"}
!10 = !{!16, !16, i64 0}
!11 = !{!17}
!12 = !{!18}
!13 = !{i32 0, i32 128}
!14 = !DILocalVariable(name: "out", scope: !19, file: !20, line: 1, type: !21)
!15 = !DILocation(line: 1, column: 1, scope: !19)
!16 = !{!"any pointer", !22}
!17 = distinct !{!17, !"scope"}
!18 = distinct !{!18, !"noscope"}
!19 = distinct !DISubprogram(name: "main", scope: !20, file: !20, line: 1, type: !23, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !24)
!20 = !DIFile(filename: "clang_attrs_intrinsics_smoke.c", directory: "/tmp")
!21 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!22 = !{!"omnipotent char"}
!23 = !DISubroutineType(types: !{!21})
!24 = distinct !DICompileUnit(language: DW_LANG_C11, file: !20, producer: "clang", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug)
