///|
/// 数组的长度前缀是 u32，写之前必须对齐到 4。
/// 之前从非对齐位置开始的数组会被接收方读成畸形消息，
/// 表现为 dbus-daemon 直接断开连接。
test "数组长度前缀前先对齐到 4" {
  let e = Encoder::new()
  e.string("x") // 4 字节长度前缀 + 'x' + NUL，落在偏移 6
  e.array(4, Bytes::makei(8, fn(_) { 0 }))
  let out = e.finish()
  // 对齐到 8 后写 4 字节长度，再 8 字节内容
  assert_eq(out.length(), 20)
  assert_eq(read_le_u32_at(out, 8), 8)
}

///|
test "array_with 同样先对齐" {
  let e = Encoder::new()
  e.string("x")
  e.array_with(4, fn(a) {
    a.i32(1)
    a.i32(2)
  })
  let out = e.finish()
  assert_eq(read_le_u32_at(out, 8), 8)
  assert_eq(out.length(), 20)
}
