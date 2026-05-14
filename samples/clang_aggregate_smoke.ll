; ModuleID = 'clang_aggregate_smoke.c'
source_filename = "clang_aggregate_smoke.c"
target datalayout = "e-m:o-i64:64-n32:64-S128"
target triple = "arm64-apple-macosx15.0.0"

%struct.Pair = type { i8, i8 }

@.pair = internal global %struct.Pair { i8 65, i8 66 }, align 1

declare i32 @putchar(i32) #1
declare void @llvm.dbg.value(metadata, metadata, metadata) #1

define internal ptr @choose() #0 {
entry:
  ret ptr @.pair
}

define i32 @main() #0 {
entry:
  %base = call ptr @choose()
  %second = getelementptr inbounds %struct.Pair, ptr %base, i64 0, i32 1
  %value = load i8, ptr %second, align 1, !dbg !10
  call void @llvm.dbg.value(metadata i8 %value, metadata !11, metadata !DIExpression()), !dbg !10
  %wide = zext i8 %value to i32
  call i32 @putchar(i32 %wide)
  ret i32 0
}

attributes #0 = { noinline nounwind optnone uwtable "frame-pointer"="non-leaf" }
attributes #1 = { nounwind }

!llvm.module.flags = !{!0}
!llvm.ident = !{!1}
!0 = !{i32 2, !"Debug Info Version", i32 3}
!1 = !{!"clang version 18.1.8"}
!10 = !DILocation(line: 1, column: 1, scope: !12)
!11 = !DILocalVariable(name: "value", scope: !12, file: !13, line: 1, type: !14)
!12 = distinct !DISubprogram(name: "main", scope: !13, file: !13, line: 1, type: !15, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !16)
!13 = !DIFile(filename: "clang_aggregate_smoke.c", directory: "/tmp")
!14 = !DIBasicType(name: "unsigned char", size: 8, encoding: DW_ATE_unsigned_char)
!15 = !DISubroutineType(types: !{!17})
!16 = distinct !DICompileUnit(language: DW_LANG_C11, file: !13, producer: "clang", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug)
!17 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
