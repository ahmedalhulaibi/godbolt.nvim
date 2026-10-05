define i32 @first() {
  ret i32 1, !dbg !10
}
define i32 @second() {
  ret i32 2, !dbg !11
}
!0 = !DIFile(filename: "{{filename}}", directory: "{{directory}}")
!1 = distinct !DISubprogram(name: "first", file: !0)
!10 = !DILocation(line: 2, column: 1, scope: !1)
!11 = !DILocation(line: 4, column: 1, scope: !1)
