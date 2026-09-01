// Copyright 2026 conglinyizhi
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// moondbus 协议层单元测试。
///
/// 字节级协议库最容易在「对齐 / 长度 / 往返一致」上出静默 bug——
/// 这些测试专门覆盖纯逻辑，不需要连总线。

// —— Encoder 基本类型 ——

///|
test "encoder writes u32 little-endian" {
  let e = Encoder::new()
  e.u32(0x12345678)
  let b = e.finish()
  assert_eq(b.length(), 4)
  // 小端：78 56 34 12
  assert_eq(b[0].to_int(), 0x78)
  assert_eq(b[1].to_int(), 0x56)
  assert_eq(b[2].to_int(), 0x34)
  assert_eq(b[3].to_int(), 0x12)
}

///|
test "encoder string has length prefix and NUL" {
  let e = Encoder::new()
  e.string("hi")
  let b = e.finish()
  // u32 长度(2) + "hi" + NUL = 4 + 2 + 1 = 7
  assert_eq(b.length(), 7)
  assert_eq(read_le_u32_at(b, 0), 2)
  assert_eq(b[4].to_int(), 'h'.to_int())
  assert_eq(b[5].to_int(), 'i'.to_int())
  assert_eq(b[6].to_int(), 0) // NUL 结尾
}

///|
test "encoder signature uses single-byte length" {
  let e = Encoder::new()
  e.signature("s")
  let b = e.finish()
  // 单字节长度(1) + "s" + NUL = 3
  assert_eq(b.length(), 3)
  assert_eq(b[0].to_int(), 1)
  assert_eq(b[1].to_int(), 's'.to_int())
  assert_eq(b[2].to_int(), 0)
}

///|
test "encoder aligns to boundary" {
  let e = Encoder::new()
  e.byte(b'\x01') // pos = 1
  e.align(8) // 应补到 8
  assert_eq(e.pos(), 8)
  e.u32(1) // pos = 12
  assert_eq(e.pos(), 12)
}

///|
test "encoder new_at respects base offset" {
  // base=4 表示这段内容在整条消息里从偏移 4 开始
  let e = Encoder::new_at(4)
  assert_eq(e.pos(), 4)
  e.byte(b'\x01') // 绝对 pos = 5
  assert_eq(e.pos(), 5)
  e.align(8) // 补到绝对 8
  assert_eq(e.pos(), 8)
}

// —— variant 编码 ——

///|
test "variant_string writes signature then value" {
  let b = build_variant_string("ok")
  // 签名 "s"(3 字节) + 对齐 + 字符串
  assert_true(b.length() > 3)
  assert_eq(b[0].to_int(), 1) // 签名长度 1
  assert_eq(b[1].to_int(), 's'.to_int())
  assert_eq(b[2].to_int(), 0)
}

///|
test "variant_with encodes arbitrary signature" {
  let e = Encoder::new()
  e.variant_with("i", fn(v) { v.i32(42) })
  let b = e.finish()
  assert_eq(b[0].to_int(), 1) // 签名长度
  assert_eq(b[1].to_int(), 'i'.to_int())
  assert_eq(b[2].to_int(), 0)
}

// —— 消息编解码往返 ——

///|
test "method call roundtrip: header fields parse back" {
  let body = build_variant_string("x")
  let msg = build_method_call(
    "com.example.Dest", "/com/example/Path", "com.example.Iface", "Ping", body, "v",
    7,
  )
  let fields = parse_header_fields(msg)
  match fields.path {
    Some(p) => assert_eq(p, "/com/example/Path")
    None => fail("path not parsed")
  }
  match fields.interface {
    Some(i) => assert_eq(i, "com.example.Iface")
    None => fail("interface not parsed")
  }
  match fields.member {
    Some(m) => assert_eq(m, "Ping")
    None => fail("member not parsed")
  }
  match fields.destination {
    Some(d) => assert_eq(d, "com.example.Dest")
    None => fail("destination not parsed")
  }
}

///|
test "parse_message extracts type and serial" {
  let body = build_variant_string("x")
  let msg = build_method_call("d", "/p", "i", "m", body, "v", 99)
  match parse_message(msg) {
    Some(m) => {
      assert_eq(m.msg_type.to_int(), 1) // METHOD_CALL
      assert_eq(m.serial, 99)
    }
    None => fail("parse_message returned None")
  }
}

///|
test "method call with empty interface omits the field" {
  let body = build_variant_string("x")
  let msg = build_method_call("d", "/p", "", "m", body, "v", 1)
  let fields = parse_header_fields(msg)
  // interface 为空时不写该字段
  assert_true(fields.interface is None)
  // 其它字段仍在
  assert_true(fields.member is Some(_))
}

// —— 字符串读取 ——

///|
test "read_dbus_string reads length-prefixed string" {
  let e = Encoder::new()
  e.string("hello")
  let b = e.finish()
  match read_dbus_string(b, 0) {
    Some(s) => assert_eq(s, "hello")
    None => fail("failed to read string")
  }
}

///|
test "read_dbus_string on truncated data returns None or empty" {
  // 长度声明 100 但实际没数据 —— 不应崩
  let e = Encoder::new()
  e.u32(100)
  let b = e.finish()
  let r = read_dbus_string(b, 0)
  assert_true(r is None || r is Some(""))
}

///|
test "read_le_u32_at reads little-endian u32" {
  let e = Encoder::new()
  e.u32(0xABCD)
  let b = e.finish()
  assert_eq(read_le_u32_at(b, 0), 0xABCD)
}

// —— 健壮性：畸形输入不崩 ——

///|
test "parse_message on too-short data returns None" {
  let short : Bytes = Bytes::makei(4, fn(_) { 0 })
  assert_true(parse_message(short) is None)
}

///|
test "parse_header_fields on too-short data returns empty fields" {
  let short : Bytes = Bytes::makei(4, fn(_) { 0 })
  let f = parse_header_fields(short)
  assert_true(f.path is None)
  assert_true(f.member is None)
}

// —— 数组 / 字典编码 ——

///|
test "array_with writes length prefix" {
  let e = Encoder::new()
  e.array_with(1, fn(a) {
    a.byte(b'\x01')
    a.byte(b'\x02')
  })
  let b = e.finish()
  // 前 4 字节是数组内容字节数
  assert_eq(read_le_u32_at(b, 0), 2)
}

///|
test "build_dict_sv encodes entries" {
  let d = build_dict_sv([("Id", "my-app"), ("Title", "My App")])
  assert_true(d.length() > 0)
  // 数组长度前缀存在
  assert_true(read_le_u32_at(d, 0) > 0)
}

///|
test "build_body_uu encodes two u32" {
  let b = build_body_uu(3, 0)
  assert_eq(b.length(), 8)
  assert_eq(read_le_u32_at(b, 0), 3)
  assert_eq(read_le_u32_at(b, 4), 0)
}

// —— Server 分发类型 ——

///|
test "Reply::make carries body and signature" {
  let r = Reply::make(build_variant_string("pong"), "v")
  assert_eq(r.signature, "v")
  assert_true(r.body.length() > 0)
}
