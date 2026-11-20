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
/// moondbus：DBus 客户端底层 —— 连接 + 认证。
/// 纯 MoonBit DBus 协议层（仅最底层 unix socket 依赖 C stub）。
///
/// 提供连接 session bus 并完成 SASL EXTERNAL 认证的能力。

// —— 底层 FFI（C stub）——
#borrow(path)
extern "c" fn connect_unix(path : Bytes) -> Int32 = "moonbit_dbus_unix_connect"

///|
extern "c" fn close_fd(fd : Int32) -> Int32 = "moonbit_dbus_close"

///|
#borrow(buf)
extern "c" fn fd_read(fd : Int32, buf : Bytes, len : Int32) -> Int32 = "moonbit_dbus_read"

///|
#borrow(buf)
extern "c" fn fd_write(fd : Int32, buf : Bytes, len : Int32) -> Int32 = "moonbit_dbus_write"

///|
extern "c" fn getuid() -> Int32 = "moonbit_dbus_getuid"

///|
/// 一个已认证的 DBus 连接。fd 是到 session bus 的 fd。
pub struct Connection {
  fd : Int32
}

///|
/// 连接并认证到 DBus session bus。
/// 成功返回 Connection，失败返回 Err(errno)。
pub fn connect_bus() -> Result[Connection, Int32] {
  let bus_path = match session_bus_path() {
    Some(path) => path
    None => return Err(2) // ENOENT: no usable session bus address
  }
  let path = @utf8.encode(bus_path)
  let fd = connect_unix(path)
  if fd < 0 {
    return Err(-fd)
  }
  // SASL EXTERNAL 认证
  let uid = getuid()
  let out = Buffer::Buffer()
  out.write_byte(0) // \0 NUL 首字节
  write_ascii(out, "AUTH EXTERNAL ")
  write_uid_hex(out, uid)
  out.write_byte(13) // \r
  out.write_byte(10) // \n
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
  Ok({ fd, })
}

///|
/// 关闭连接。
pub fn close(conn : Connection) -> Unit {
  let _ = close_fd(conn.fd)
}

///|
/// 发送原始字节到连接。返回写入字节数。
pub fn send_raw(conn : Connection, data : Bytes) -> Result[Int32, Int32] {
  guard_blocking("send_raw")
  let w = fd_write(conn.fd, data, data.length())
  if w < 0 {
    Err(-w)
  } else {
    Ok(w)
  }
}

///|
/// 从连接读原始字节（最多 len）。返回读到的字节数。
pub fn recv_raw(conn : Connection, len : Int32) -> Result[Bytes, Int32] {
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
pub fn recv_message(conn : Connection) -> Result[Bytes, Int32] {
  guard_blocking("recv_message")
  // 1) 读 16 字节固定头。短读要继续读：一次 read 不保证读满，
  //    早先版本短读直接报错，会把常驻服务循环直接结束掉。
  let head_buf = Buffer::Buffer()
  match read_exact_into(conn, head_buf, 16) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let head = head_buf.to_bytes()
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
  // 3) 读剩余，同样读满为止
  let body_buf = Buffer::Buffer()
  match read_exact_into(conn, body_buf, total_rest) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  // 4) 拼接
  let out = Buffer::Buffer()
  out.write_bytes(head)
  out.write_bytes(body_buf.to_bytes())
  Ok(out.to_bytes())
}

///|
/// 从连接读满 need 字节追加到 buf；短读继续读，对端关闭返回 Err(0)。
fn read_exact_into(
  conn : Connection,
  buf : Buffer,
  need : Int32,
) -> Result[Unit, Int32] {
  let mut got = 0
  while got < need {
    let tmp : Bytes = Bytes::makei(need - got, fn(_) { 0 })
    let n = fd_read(conn.fd, tmp, need - got)
    if n < 0 {
      return Err(-n)
    }
    if n == 0 {
      return Err(0)
    }
    buf.write_bytes(tmp[:n])
    got = got + n
  }
  Ok(())
}

///|
/// 读小端 u32。
fn le_u32(data : Bytes, off : Int32) -> Int32 {
  let mut v = 0
  let mut i = 0
  while i < 4 && off + i < data.length() {
    v = v | (data[off + i].to_int() << (8 * i))
    i = i + 1
  }
  v
}

///|
/// 从当前环境解析出 session bus 的 Unix socket 路径。
///
/// D-Bus 地址可能包含多个候选地址和地址参数；这里选第一个
/// `unix:path=...` 地址。当前底层只支持 filesystem Unix sockets，
/// 因此其它地址形式会被跳过。
fn session_bus_path() -> String? {
  match @env.get_env_var("DBUS_SESSION_BUS_ADDRESS") {
    Some(address) => dbus_path_from_address(address)
    None => Some("/run/user/\{getuid()}/bus")
  }
}

///|
/// 从 D-Bus 地址解析出 Unix socket 路径。
///
/// 只返回第一个可用的 `unix:path=...` 地址。地址值支持 D-Bus 常见的
/// percent encoding（例如 `%2F` 表示 `/`）。
fn dbus_path_from_address(addr : String) -> String? {
  for candidate in addr.split(";") {
    let candidate = candidate.to_owned()
    if !candidate.has_prefix("unix:") {
      continue
    }
    for option in candidate[5:].split(",") {
      let option = option.to_owned()
      if option.has_prefix("path=") {
        let path = percent_decode(option[5:])
        if path != "" {
          return Some(path)
        }
      }
    }
  }
  None
}

///|
/// 解码 D-Bus 地址参数中的 `%HH` percent encoding。
/// 无效编码原样保留，避免把合法但未知的地址内容静默改坏。
fn percent_decode(value : StringView) -> String {
  let out = Buffer::Buffer()
  let bytes = @utf8.encode(value)
  let mut i = 0
  while i < bytes.length() {
    if bytes[i] == b'%' && i + 2 < bytes.length() {
      match (hex_value(bytes[i + 1]), hex_value(bytes[i + 2])) {
        (Some(high), Some(low)) => {
          out.write_byte((high * 16 + low).to_byte())
          i = i + 3
          continue
        }
        (_, _) => ()
      }
    }
    out.write_byte(bytes[i])
    i = i + 1
  }
  @utf8.decode_lossy(out.to_bytes())
}

///|
fn hex_value(b : Byte) -> Int32? {
  let value = b.to_int()
  if value >= 48 && value <= 57 {
    Some(value - 48)
  } else if value >= 65 && value <= 70 {
    Some(value - 55)
  } else if value >= 97 && value <= 102 {
    Some(value - 87)
  } else {
    None
  }
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
fn write_uid_hex(out : Buffer, uid : Int32) -> Unit {
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
fn hex_digit_byte(v : Int32) -> Byte {
  if v < 10 {
    (48 + v).to_byte()
  } else {
    (55 + v).to_byte()
  }
}

///|
fn write_byte(out : Buffer, b : Byte) -> Unit {
  out.write_byte(b)
}

///|
/// 返回当前进程 pid（用于构造 DBus bus name，如 SNI 托盘项）。
pub fn getpid() -> Int32 {
  getpid_ffi()
}

///|
extern "c" fn getpid_ffi() -> Int32 = "moonbit_dbus_getpid"

///|
extern "c" fn wait_readable_raw(fd : Int32, timeout_ms : Int32) -> Int32 = "moonbit_dbus_wait_readable"

///|
/// 等这条连接可读。返回 true 表示有数据，false 表示等到超时。
///
/// 给常驻服务循环用：想在有消息前做点定期工作，就在这里等一小段，超时了回去干活。
pub fn Connection::wait_readable(conn : Connection, timeout_ms : Int32) -> Bool {
  guard_blocking("wait_readable")
  wait_readable_raw(conn.fd, timeout_ms) > 0
}
