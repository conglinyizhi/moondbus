///|
/// moondbus：DBus 高层调用 API。
/// 封装「构造消息 → 发送 → 接收 → 解析」，供上层（SNI 托盘等）直接使用。

///|
/// 发起一次方法调用并等待回复。
/// 返回解析后的 Message（METHOD_RETURN 或 ERROR）。
pub fn call(
  conn : Connection,
  destination : String,
  path : String,
  interface : String,
  member : String,
  body : Bytes,
  signature : String,
  serial : Int,
) -> Result[Message, Int] {
  let msg = build_method_call(
    destination, path, interface, member, body, signature, serial,
  )
  match send_raw(conn, msg) {
    Err(e) => Err(e)
    Ok(_) => {
      // 循环读消息，直到遇到 METHOD_RETURN(2) 或 ERROR(3)
      // （期间可能先收到 NameAcquired 等信号 SIGNAL(4)）
      let mut tries = 0
      let mut result : Result[Message, Int] = Err(-1)
      while tries < 10 {
        match recv_message(conn) {
          Err(e) => {
            result = Err(e)
            break
          }
          Ok(raw) =>
            match parse_message(raw) {
              None => {
                result = Err(-2)
                break
              }
              Some(m) => {
                let t = m.msg_type.to_int()
                if t == 2 || t == 3 {
                  result = Ok(m)
                  break
                }
                // 信号等其他消息，继续读
              }
            }
        }
        tries = tries + 1
      }
      result
    }
  }
}

///|
/// 无参数、无返回体的简易调用（常用于 SNI 注册等）。
pub fn call_simple(
  conn : Connection,
  destination : String,
  path : String,
  interface : String,
  member : String,
  serial : Int,
) -> Result[Message, Int] {
  let empty : Bytes = Bytes::makei(0, fn(_) { 0 })
  call(conn, destination, path, interface, member, empty, "", serial)
}

///|
/// 单个字符串参数的调用（如 RegisterStatusNotifierItem(service)）。
pub fn call_with_string(
  conn : Connection,
  destination : String,
  path : String,
  interface : String,
  member : String,
  arg : String,
  serial : Int,
) -> Result[Message, Int] {
  // body：一个 DBus string（u32 长度 + 内容 + NUL）
  let b = Buffer::Buffer()
  let bs = @utf8.encode(arg)
  let mut i = 0
  while i < 4 {
    b.write_byte(((bs.length() >> (8 * i)) & 0xFF).to_byte())
    i = i + 1
  }
  b.write_bytes(bs)
  b.write_byte(0)
  call(conn, destination, path, interface, member, b.to_bytes(), "s", serial)
}

///|
/// 执行 DBus 握手 Hello（连接后必须首先调用）。
/// 返回我们的唯一连接名（如 ":1.448"）。
pub fn hello(conn : Connection) -> Result[String, Int] {
  match
    call_simple(
      conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
      "Hello", 1,
    ) {
    Err(e) => Err(e)
    Ok(m) =>
      match read_dbus_string(m.body, 0) {
        Some(name) => Ok(name)
        None => Err(-2)
      }
  }
}

///|
/// 申请一个 bus name（RequestName）。
/// flags: 0 = 默认；返回 u32 结果码（1 = PRIMARY_OWNER）。
pub fn request_name(
  conn : Connection,
  name : String,
  flags : Int,
  serial : Int,
) -> Result[Int, Int] {
  // body: string + u32
  let b = Buffer::Buffer()
  let bs = @utf8.encode(name)
  put_le_u32(b, bs.length())
  b.write_bytes(bs)
  b.write_byte(0)
  // u32 参数需 4 字节对齐
  while b.length() % 4 != 0 {
    b.write_byte(0)
  }
  put_le_u32(b, flags)
  match
    call(
      conn,
      "org.freedesktop.DBus",
      "/org/freedesktop/DBus",
      "org.freedesktop.DBus",
      "RequestName",
      b.to_bytes(),
      "su",
      serial,
    ) {
    Err(e) => Err(e)
    Ok(m) =>
      if m.body.length() >= 4 {
        Ok(read_le_u32(m.body, 0))
      } else {
        Err(-3)
      }
  }
}

///|
/// 写小端 u32 到 Buffer。
fn put_le_u32(b : Buffer, v : Int) -> Unit {
  let mut i = 0
  while i < 4 {
    b.write_byte(((v >> (8 * i)) & 0xFF).to_byte())
    i = i + 1
  }
}

///|
/// 读小端 u32。
fn read_le_u32(data : Bytes, off : Int) -> Int {
  let mut v = 0
  let mut i = 0
  while i < 4 && off + i < data.length() {
    v = v | (data[off + i].to_int() << (8 * i))
    i = i + 1
  }
  v
}

///|
/// 发送一条信号（不等待回复）。
pub fn emit_signal(
  conn : Connection,
  path : String,
  interface : String,
  member : String,
  body : Bytes,
  signature : String,
  serial : Int,
) -> Result[Int, Int] {
  let msg = build_signal(path, interface, member, body, signature, serial)
  send_raw(conn, msg)
}
