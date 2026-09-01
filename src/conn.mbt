///|
/// moonbit-kde-sni：DBus 客户端底层 —— 连接 + 认证。
/// 纯 MoonBit DBus 协议层（仅最底层 unix socket 依赖 C stub）。
///
/// 提供连接 session bus 并完成 SASL EXTERNAL 认证的能力。

// —— 底层 FFI（C stub）——
#borrow(path)
extern "c" fn connect_unix(path : Bytes) -> Int = "moonbit_dbus_unix_connect"
extern "c" fn close_fd(fd : Int) -> Int = "moonbit_dbus_close"
#borrow(buf)
extern "c" fn fd_read(fd : Int, buf : Bytes, len : Int) -> Int = "moonbit_dbus_read"
#borrow(buf)
extern "c" fn fd_write(fd : Int, buf : Bytes, len : Int) -> Int = "moonbit_dbus_write"
extern "c" fn getuid() -> Int = "moonbit_dbus_getuid"

///|
/// 一个已认证的 DBus 连接。fd 是到 session bus 的 fd。
pub struct Connection {
  fd : Int
}

///|
/// DBus 常量。
const DBUS_SESSION_BUS : String = "unix:path=/run/user/1000/bus"

///|
/// 连接并认证到 DBus session bus。
/// 成功返回 Connection，失败返回 Err(errno)。
pub fn connect_bus() -> Result[Connection, Int] {
  let bus_path = dbus_path_from_address(DBUS_SESSION_BUS)
  let path = @utf8.encode(bus_path)
  let fd = connect_unix(path)
  if fd < 0 {
    return Err(-fd)
  }
  // SASL EXTERNAL 认证
  let uid = getuid()
  let out = Buffer::Buffer()
  out.write_byte(0)                       // \0 NUL 首字节
  write_ascii(out, "AUTH EXTERNAL ")
  write_uid_hex(out, uid)
  out.write_byte(13)                      // \r
  out.write_byte(10)                      // \n
  let auth_bytes = out.to_bytes()
  let _ = fd_write(fd, auth_bytes, auth_bytes.length())

  // 读回复（最多 512 字节）
  let buf : Bytes = Bytes::makei(512, fn(_) { 0 })
  let n = fd_read(fd, buf, 512)
  if n <= 0 {
    let _ = close_fd(fd)
    return Err(-n)
  }
  let reply = @utf8.decode_lossy(buf[:n])
  if !reply.has_prefix("OK ") {
    // 未认证成功（如 REJECTED），关闭并报错
    let _ = close_fd(fd)
    return Err(1)
  }
  // 认证成功后必须发 BEGIN\r\n，才能开始传二进制消息
  let begin = Buffer::Buffer()
  write_ascii(begin, "BEGIN\r\n")
  let begin_bytes = begin.to_bytes()
  let _ = fd_write(fd, begin_bytes, begin_bytes.length())
  Ok({ fd })
}

///|
/// 关闭连接。
pub fn close(conn : Connection) -> Unit {
  let _ = close_fd(conn.fd)
}

///|
/// 发送原始字节到连接。返回写入字节数。
pub fn send_raw(conn : Connection, data : Bytes) -> Result[Int, Int] {
  let w = fd_write(conn.fd, data, data.length())
  if w < 0 {
    Err(-w)
  } else {
    Ok(w)
  }
}

///|
/// 从连接读原始字节（最多 len）。返回读到的字节数。
pub fn recv_raw(conn : Connection, len : Int) -> Result[Bytes, Int] {
  let buf : Bytes = Bytes::makei(len, fn(_) { 0 })
  let n = fd_read(conn.fd, buf, len)
  if n <= 0 {
    Err(if n == 0 { 0 } else { -n })
  } else {
    Ok(buf[:n].to_owned())
  }
}

///|
/// 读一条完整的 DBus 消息（按消息边界）。
/// DBus 是流式协议，一次 read 可能含多条消息或不完整。
/// 此函数先读 16 字节固定头，算出总长，再读剩余部分。
pub fn recv_message(conn : Connection) -> Result[Bytes, Int] {
  // 1) 读 16 字节固定头
  let head : Bytes = Bytes::makei(16, fn(_) { 0 })
  let n1 = fd_read(conn.fd, head, 16)
  if n1 <= 0 {
    return Err(if n1 == 0 { 0 } else { -n1 })
  }
  if n1 < 16 {
    return Err(-100)  // 头不完整
  }
  // 2) 算出总长：16 + fields_len(对齐到8) + body_len
  let body_len = le_u32(head, 4)
  let fields_len = le_u32(head, 12)
  let mut rest = fields_len
  while (16 + rest) % 8 != 0 {
    rest = rest + 1
  }
  let total_rest = rest + body_len
  if total_rest <= 0 {
    return Ok(head)
  }
  // 3) 读剩余
  let tail : Bytes = Bytes::makei(total_rest, fn(_) { 0 })
  let mut got = 0
  while got < total_rest {
    let n2 = fd_read(conn.fd, tail, total_rest - got)
    if n2 <= 0 {
      break
    }
    got = got + n2
  }
  // 4) 拼接
  let out = Buffer::Buffer()
  out.write_bytes(head)
  out.write_bytes(tail[:got])
  Ok(out.to_bytes())
}

///|
/// 读小端 u32。
fn le_u32(data : Bytes, off : Int) -> Int {
  let mut v = 0
  let mut i = 0
  while i < 4 && off + i < data.length() {
    v = v | (data[off + i].to_int() << (8 * i))
    i = i + 1
  }
  v
}

///|
/// 从 DBus 地址解析出 unix socket 路径。
/// 当前固定为 session bus 路径（DBUS_SESSION_BUS 不再解析，直接用常量）。
fn dbus_path_from_address(_addr : String) -> String {
  "/run/user/1000/bus"
}

///|
/// 写 ascii 字符串到 Buffer（UTF-8 字节）。
fn write_ascii(out : Buffer, s : String) -> Unit {
  out.write_bytes(@utf8.encode(s))
}

///|
/// 写一个字节的两位 ascii hex。
fn write_hex_byte(out : Buffer, b : Byte) -> Unit {
  let v = b.to_int()
  write_byte(out, hex_digit_byte(v / 16))
  write_byte(out, hex_digit_byte(v % 16))
}

///|
/// 写 uid 的 hex 字符串（DBus EXTERNAL 要求 uid 的十进制 ascii 再 hex）。
fn write_uid_hex(out : Buffer, uid : Int) -> Unit {
  let s = uid.to_string()
  let bs = @utf8.encode(s)
  let mut i = 0
  while i < bs.length() {
    write_hex_byte(out, bs[i])
    i = i + 1
  }
}

///|
/// 单个十六进制数字的 ascii 字节。
fn hex_digit_byte(v : Int) -> Byte {
  if v < 10 {
    (48 + v).to_byte()
  } else {
    (55 + v).to_byte()
  }
}

fn write_byte(out : Buffer, b : Byte) -> Unit {
  out.write_byte(b)
}

///|
/// 返回当前进程 pid（用于构造 DBus bus name，如 SNI 托盘项）。
pub fn getpid() -> Int {
  getpid_ffi()
}

extern "c" fn getpid_ffi() -> Int = "moonbit_dbus_getpid"
