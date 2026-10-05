define i32 @selected() !dbg !2 {
  ret i32 42, !dbg !4
}
define i32 @other() !dbg !3 {
  ret i32 99, !dbg !5
}
!0 = !DIFile(filename: "example.zig", directory: "/tmp")
!1 = !DIFile(filename: "other.zig", directory: "/tmp")
!2 = distinct !DISubprogram(name: "selected", file: !0)
!3 = distinct !DISubprogram(name: "other", file: !1)
!4 = !DILocation(line: 2, column: 5, scope: !6)
!5 = !DILocation(line: 2, column: 5, scope: !3)
!6 = distinct !DILexicalBlock(scope: !2)
