///|
/// moondbus：DBus 消息层 —— 消息 wire 编解码（方法调用 / 回复）。
/// 遵循 DBus 协议（小端，仅实现所需类型：y u s o g v a）。
///
/// 最小实现：构造/解析 METHOD_CALL 与 METHOD_RETURN，支持 Hello 调用。

// —— 消息类型 ——
const MSG_METHOD_CALL : Byte = 1

///|
const MSG_METHOD_RETURN : Byte = 2

// —— Header Field Code ——

///|
const FIELD_PATH : Byte = 1

///|
const FIELD_INTERFACE : Byte = 2

///|
const FIELD_MEMBER : Byte = 3

///|
const FIELD_REPLY_SERIAL : Byte = 5

///|
const FIELD_DESTINATION : Byte = 6

///|
const FIELD_SIGNATURE : Byte = 8

///|
/// 对齐 Buffer 到 n 字节边界。
fn align_buf(b : Buffer, n : Int) -> Unit {
  while b.length() % n != 0 {
    b.write_byte(0)
  }
}

///|
/// 写小端 u32。
fn put_u32(b : Buffer, v : Int) -> Unit {
  let mut i = 0
  while i < 4 {
    b.write_byte(((v >> (8 * i)) & 0xFF).to_byte())
    i = i + 1
  }
}

///|
/// 写字符串（s/o/g 类型）：u32 长度 + 字节 + NUL。
fn put_string(b : Buffer, s : String) -> Unit {
  let bs = @utf8.encode(s)
  put_u32(b, bs.length())
  b.write_bytes(bs)
  b.write_byte(0)
}

///|
/// 写签名（g 类型）：1 字节长度 + 内容 + NUL（注意：不是 u32！）。
fn put_signature(b : Buffer, s : String) -> Unit {
  let bs = @utf8.encode(s)
  b.write_byte(bs.length().to_byte())
  b.write_bytes(bs)
  b.write_byte(0)
}

///|
/// 写一个 header field：struct (yv)，需 8 字节对齐。
/// y = field code，v = variant（signature + 值）。
/// 注意：值为 g 类型时（如 SIGNATURE 字段），长度是 1 字节而非 u32。
fn put_field(b : Buffer, code : Byte, sig : String, value : String) -> Unit {
  align_buf(b, 8) // struct 对齐到 8
  b.write_byte(code) // y
  put_signature(b, sig) // variant 的 signature（g：1字节长度）
  if sig == "g" {
    // 值也是 g 类型：1 字节长度 + 内容 + NUL（无需 4 对齐）
    put_signature(b, value)
  } else {
    align_buf(b, 4) // s/o 值对齐到 4
    put_string(b, value)
  }
}

///|
/// 构造一条 METHOD_CALL 消息（小端，仅 header + 可选 body）。
pub fn build_method_call(
  destination : String,
  path : String,
  interface : String,
  member : String,
  body : Bytes,
  signature : String,
  serial : Int,
) -> Bytes {
  let b = Buffer::Buffer()
  b.write_byte(0x6C) // endianness 'l'
  b.write_byte(MSG_METHOD_CALL)
  b.write_byte(0) // flags
  b.write_byte(1) // version
  put_u32(b, body.length()) // body length
  put_u32(b, serial) // serial

  // header fields a(yv)，顺序与标准实现一致（影响对齐填充）
  let hf = Buffer::Buffer()
  put_field(hf, FIELD_PATH, "o", path)
  put_field(hf, FIELD_DESTINATION, "s", destination)
  if interface.length() > 0 {
    put_field(hf, FIELD_INTERFACE, "s", interface)
  }
  put_field(hf, FIELD_MEMBER, "s", member)
  if signature.length() > 0 {
    put_field(hf, FIELD_SIGNATURE, "g", signature)
  }
  put_u32(b, hf.length())
  b.write_bytes(hf.to_bytes())
  // body 开始前对齐到 8
  align_buf(b, 8)
  b.write_bytes(body)
  b.to_bytes()
}

///|
/// 解析一条消息，提取 header 的 type / serial / body。
pub fn parse_message(data : Bytes) -> Message? {
  if data.length() < 16 {
    return None
  }
  let msg_type = data[1] // offset 1 = type
  let body_len = read_u32(data, 4) // offset 4 = body length
  let serial = read_u32(data, 8) // offset 8 = serial
  let fields_len = read_u32(data, 12) // offset 12 = fields length
  // fields 之后对齐到 8，再是 body
  let mut body_start = 16 + fields_len
  while body_start % 8 != 0 {
    body_start = body_start + 1
  }
  let body = if body_start + body_len <= data.length() {
    data[body_start:body_start + body_len].to_owned()
  } else {
    Bytes::makei(0, fn(_) { 0 })
  }
  Some({ msg_type, serial, body, reply_serial: None, })
}

///|
/// 从 body 里读一个 DBus 字符串（u32 长度 + 内容）。
pub fn read_dbus_string(body : Bytes, off : Int) -> String? {
  if off + 4 > body.length() {
    return None
  }
  let len = read_u32(body, off)
  let start = off + 4
  if start + len > body.length() {
    return None
  }
  Some(@utf8.decode_lossy(body[start:start + len]))
}

///|
/// 读小端 u32。
fn read_u32(data : Bytes, off : Int) -> Int {
  let mut v = 0
  let mut i = 0
  while i < 4 && off + i < data.length() {
    v = v | (data[off + i].to_int() << (8 * i))
    i = i + 1
  }
  v
}

///|
/// 解码后的消息。
pub struct Message {
  msg_type : Byte
  serial : Int
  body : Bytes
  reply_serial : Int?
}

///|
/// 解析出的 header 字段（我们关心的几个）。
pub struct HeaderFields {
  path : String?
  interface : String?
  member : String?
  destination : String?
  sender : String?
  reply_serial : Int?
  signature : String?
}

///|
/// 从消息里解析 header fields（a(yv)）。
/// 用于服务端响应：判断 KDE 请求的是哪个接口/方法。
pub fn parse_header_fields(data : Bytes) -> HeaderFields {
  let mut path : String? = None
  let mut interface : String? = None
  let mut member : String? = None
  let mut destination : String? = None
  let mut sender : String? = None
  let mut reply_serial : Int? = None
  let mut signature : String? = None
  if data.length() < 16 {
    return {
      path,
      interface,
      member,
      destination,
      sender,
      reply_serial,
      signature,
    }
  }
  let fields_len = read_u32(data, 12)
  let start = 16
  let end = start + fields_len
  let mut i = start
  while i < end && i < data.length() {
    // struct 8 字节对齐（相对消息起点）
    while i % 8 != 0 && i < end {
      i = i + 1
    }
    if i >= end || i >= data.length() {
      break
    }
    let code = data[i].to_int()
    i = i + 1
    // variant: signature(g: 1字节长度 + 内容 + NUL)
    if i >= data.length() {
      break
    }
    let sig_len = data[i].to_int()
    i = i + 1
    let sig = if i + sig_len <= data.length() {
      @utf8.decode_lossy(data[i:i + sig_len])
    } else {
      ""
    }
    i = i + sig_len + 1 // 跳过签名内容 + NUL
    // 值
    if sig == "u" {
      // u32：先对齐到 4
      while i % 4 != 0 && i < data.length() {
        i = i + 1
      }
      if i + 4 <= data.length() {
        let v = read_u32(data, i)
        if code == 5 {
          reply_serial = Some(v)
        }
        i = i + 4
      }
    } else if sig == "g" {
      // g 值：1 字节长度
      if i < data.length() {
        let l = data[i].to_int()
        i = i + 1
        let v = if i + l <= data.length() {
          @utf8.decode_lossy(data[i:i + l])
        } else {
          ""
        }
        if code == 8 {
          signature = Some(v)
        }
        i = i + l + 1
      }
    } else {
      // s/o：对齐到 4，u32 长度 + 内容 + NUL
      while i % 4 != 0 && i < data.length() {
        i = i + 1
      }
      if i + 4 <= data.length() {
        let l = read_u32(data, i)
        i = i + 4
        let v = if i + l <= data.length() {
          @utf8.decode_lossy(data[i:i + l])
        } else {
          ""
        }
        if code == 1 {
          path = Some(v)
        } else if code == 2 {
          interface = Some(v)
        } else if code == 3 {
          member = Some(v)
        } else if code == 6 {
          destination = Some(v)
        } else if code == 7 {
          sender = Some(v)
        }
        i = i + l + 1
      }
    }
  }
  { path, interface, member, destination, sender, reply_serial, signature, }
}

///|
/// 写一个 u32 类型的 header field（如 REPLY_SERIAL）。
fn put_field_u32(b : Buffer, code : Byte, value : Int) -> Unit {
  align_buf(b, 8)
  b.write_byte(code)
  put_signature(b, "u")
  align_buf(b, 4)
  put_u32(b, value)
}

///|
/// 构造 METHOD_RETURN 回复消息。
/// reply_serial: 对应请求的 serial；destination: 请求方的唯一名。
pub fn build_method_return(
  destination : String,
  reply_serial : Int,
  body : Bytes,
  signature : String,
  serial : Int,
) -> Bytes {
  let b = Buffer::Buffer()
  b.write_byte(0x6C) // little endian
  b.write_byte(MSG_METHOD_RETURN) // type = 2
  b.write_byte(0) // flags
  b.write_byte(1) // version
  put_u32(b, body.length())
  put_u32(b, serial)
  // header fields
  let hf = Buffer::Buffer()
  put_field_u32(hf, FIELD_REPLY_SERIAL, reply_serial)
  if destination.length() > 0 {
    put_field(hf, FIELD_DESTINATION, "s", destination)
  }
  if signature.length() > 0 {
    put_field(hf, FIELD_SIGNATURE, "g", signature)
  }
  put_u32(b, hf.length())
  b.write_bytes(hf.to_bytes())
  align_buf(b, 8)
  b.write_bytes(body)
  b.to_bytes()
}

///|
/// 构造一个 variant 值（用于属性返回）：signature + 值。
/// 仅支持字符串类型 variant（"s"）。
pub fn build_variant_string(value : String) -> Bytes {
  let b = Buffer::Buffer()
  put_signature(b, "s")
  align_buf(b, 4)
  put_string(b, value)
  b.to_bytes()
}

///|
/// 构造一个 a{sv} 字典（属性名 -> 字符串值的 variant）。
/// 用于 org.freedesktop.DBus.Properties.GetAll 的回复。
/// entries: [(key, value_string), ...]
pub fn build_dict_sv(entries : Array[(String, String)]) -> Bytes {
  // 先构造数组内容（每个 dict entry 8 字节对齐）
  let inner = Buffer::Buffer()
  for e in entries {
    let (k, v) = e
    // dict entry 对齐到 8
    while inner.length() % 8 != 0 {
      inner.write_byte(0)
    }
    // key: s
    put_string(inner, k)
    // value: v = signature("s") + align(4) + string
    put_signature(inner, "s")
    while inner.length() % 4 != 0 {
      inner.write_byte(0)
    }
    put_string(inner, v)
  }
  let inner_bytes = inner.to_bytes()
  // 数组：u32 长度 + 对齐到 8 + 内容
  let out = Buffer::Buffer()
  put_u32(out, inner_bytes.length())
  // 数组元素起点需对齐到 8（相对于消息，这里 body 起点已是 8 对齐，
  // u32 长度占 4 字节，所以要补 4 字节到 8 边界）
  while out.length() % 8 != 0 {
    out.write_byte(0)
  }
  out.write_bytes(inner_bytes)
  out.to_bytes()
}

///|
/// 读小端 u32（公开，供上层解析 body 使用）。
pub fn read_le_u32_at(data : Bytes, off : Int) -> Int {
  read_u32(data, off)
}

// —— 信号（SIGNAL, type=4）——

///|
const MSG_SIGNAL : Byte = 4

///|
/// 构造一条 SIGNAL 消息。
/// 信号是广播/单向的，不需要回复，也不需要 destination（可选）。
/// 必需 header 字段：PATH、INTERFACE、MEMBER。
pub fn build_signal(
  path : String,
  interface : String,
  member : String,
  body : Bytes,
  signature : String,
  serial : Int,
) -> Bytes {
  let b = Buffer::Buffer()
  b.write_byte(0x6C) // little endian
  b.write_byte(MSG_SIGNAL) // type = 4
  b.write_byte(0) // flags
  b.write_byte(1) // version
  put_u32(b, body.length())
  put_u32(b, serial)
  let hf = Buffer::Buffer()
  put_field(hf, FIELD_PATH, "o", path)
  put_field(hf, FIELD_INTERFACE, "s", interface)
  put_field(hf, FIELD_MEMBER, "s", member)
  if signature.length() > 0 {
    put_field(hf, FIELD_SIGNATURE, "g", signature)
  }
  put_u32(b, hf.length())
  b.write_bytes(hf.to_bytes())
  align_buf(b, 8)
  b.write_bytes(body)
  b.to_bytes()
}

///|
/// 构造两个 u32/i32 参数的 body（如 dbusmenu 的 LayoutUpdated(revision, parent)）。
pub fn build_body_uu(a : Int, b2 : Int) -> Bytes {
  let b = Buffer::Buffer()
  put_u32(b, a)
  put_u32(b, b2)
  b.to_bytes()
}
