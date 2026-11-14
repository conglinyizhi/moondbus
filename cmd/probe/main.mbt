///|
#borrow(path)
extern "c" fn listen_unix(path : Bytes, backlog : Int32) -> Int32 = "moonbit_probe_listen"

///|
extern "c" fn accept_conn(fd : Int32) -> Int32 = "moonbit_probe_accept"

///|
#borrow(path)
extern "c" fn connect_unix(path : Bytes) -> Int32 = "moonbit_probe_connect"

///|
extern "c" fn poll2(a : Int32, b : Int32, timeout_ms : Int32) -> Int32 = "moonbit_probe_poll2"

///|
#borrow(buf)
extern "c" fn read_fd(fd : Int32, buf : Bytes, len : Int32) -> Int32 = "moonbit_probe_read"

///|
#borrow(buf)
extern "c" fn write_fd(fd : Int32, buf : Bytes, len : Int32) -> Int32 = "moonbit_probe_write"

///|
extern "c" fn close_fd(fd : Int32) -> Int32 = "moonbit_probe_close"

///|
fn cstr(s : String) -> Bytes {
  let src = @utf8.encode(s)
  let n = src.length()
  Bytes::makei(n + 1, fn(i) { if i < n { src[i] } else { 0 } })
}

///|
fn le_u32(a : Array[Byte], off : Int32) -> Int32 {
  let mut v = 0
  for i in 0..<4 {
    v = v | (a[off + i].to_int() << (8 * i))
  }
  v
}

///|
fn hex_of(a : Array[Byte]) -> String {
  let out = StringBuilder()
  for i in 0..<a.length() {
    let v = a[i].to_int()
    let hi = (v >> 4) & 0xF
    let lo = v & 0xF
    out.write_char((if hi < 10 { 48 + hi } else { 87 + hi }).unsafe_to_char())
    out.write_char((if lo < 10 { 48 + lo } else { 87 + lo }).unsafe_to_char())
  }
  out.to_string()
}

///|
/// 一条 D-Bus 报文的总长：16 字节定长头 + fields（补到 8）+ body。
fn message_len(a : Array[Byte]) -> Int32? {
  if a.length() < 16 {
    return None
  }
  let body = le_u32(a, 4)
  let fields = le_u32(a, 12)
  let head = 16 + fields
  let aligned = (head + 7) / 8 * 8
  let total = aligned + body
  if total <= 0 || total > 16 * 1024 * 1024 {
    // 长度不合理：宁可停下也不越界读
    None
  } else if a.length() < total {
    None
  } else {
    Some(total)
  }
}

///|
/// 立即把字节转发给对端（不等待报文边界：SASL 握手不是 D-Bus 报文）。
fn forward(peer : Int32, bytes : Array[Byte]) -> Unit {
  if bytes.length() == 0 {
    return
  }
  let buf = Bytes::from_array(bytes)
  let mut off = 0
  while off < bytes.length() {
    let n = write_fd(peer, buf, bytes.length())
    if n <= 0 {
      eprintln("转发失败: \{n}")
      return
    }
    off = off + n
  }
}

///|
/// 尽力分帧打日志：认不出 D-Bus 报文就把这一批当裸数据记下来。
fn log_frames(dir : String, buf : Array[Byte], verbose : Bool) -> Array[Byte] {
  let mut rest = buf
  while rest.length() > 0 {
    // D-Bus 定长头：0 字节是字节序标记 'l'/'B'，3 字节是协议版本 1
    let looks_like_msg = rest.length() >= 16 &&
      (rest[0].to_int() == 0x6C || rest[0].to_int() == 0x42) &&
      rest[3].to_int() == 1
    if !looks_like_msg {
      if verbose {
        eprintln("\{dir} RAW len=\{rest.length()} \{hex_of(rest)}")
      }
      return []
    }
    match message_len(rest) {
      None => return rest
      Some(total) => {
        let msg : Array[Byte] = []
        for i in 0..<total {
          msg.push(rest[i])
        }
        let kind = msg[1].to_int()
        let serial = le_u32(msg, 8)
        eprintln(
          "\{dir} len=\{total} type=\{kind} serial=\{serial} \{hex_of(msg)}",
        )
        let next : Array[Byte] = []
        for i in total..<rest.length() {
          next.push(rest[i])
        }
        rest = next
      }
    }
  }
  rest
}

///|
fn relay(client : Int32, upstream : Int32, verbose : Bool) -> Unit {
  let mut log_c : Array[Byte] = []
  let mut log_s : Array[Byte] = []
  while true {
    let mask = poll2(client, upstream, 1000)
    if mask < 0 {
      break
    }
    if (mask & 1) != 0 {
      let tmp = Bytes::makei(65536, fn(_) { 0 })
      let n = read_fd(client, tmp, 65536)
      if n <= 0 {
        break
      }
      let chunk : Array[Byte] = []
      for i in 0..<n {
        chunk.push(tmp[i])
      }
      forward(upstream, chunk)
      for b in chunk {
        log_c.push(b)
      }
      log_c = log_frames("C>", log_c, verbose)
    }
    if (mask & 2) != 0 {
      let tmp = Bytes::makei(65536, fn(_) { 0 })
      let n = read_fd(upstream, tmp, 65536)
      if n <= 0 {
        break
      }
      let chunk : Array[Byte] = []
      for i in 0..<n {
        chunk.push(tmp[i])
      }
      forward(client, chunk)
      for b in chunk {
        log_s.push(b)
      }
      log_s = log_frames("S>", log_s, verbose)
    }
  }
}

///|
fn bus_path() -> String {
  "/run/user/1000/bus"
}

///|
fn main raise {
  let cmd = @argparse.Command(
    "moondbus-probe",
    about="字节级 D-Bus 中转，把每条报文记成 hex",
    options=[
      @argparse.OptionArg("listen", about="监听地址（unix 路径）", default_values=[
        "/tmp/moondbus-probe.sock",
      ]),
      @argparse.OptionArg("upstream", about="上游 bus 路径", default_values=[
        bus_path(),
      ]),
      @argparse.OptionArg("verbose", about="是否在 stderr 逐条打印", default_values=[
        "false",
      ]),
    ],
  )
  let m = cmd.parse()
  let listen = match m.values.get("listen") {
    Some([v, ..]) => v
    _ => "/tmp/moondbus-probe.sock"
  }
  let upstream = match m.values.get("upstream") {
    Some([v, ..]) => v
    _ => bus_path()
  }
  let verbose = match m.values.get("verbose") {
    Some(["true", ..]) => true
    _ => false
  }
  let lfd = listen_unix(cstr(listen), 4)
  if lfd < 0 {
    eprintln("监听失败: \{lfd}")
    return
  }
  eprintln("moondbus-probe 监听 unix:path=\{listen} → \{upstream}")
  for ;; {
    let client = accept_conn(lfd)
    if client < 0 {
      eprintln("accept 失败: \{client}")
      break
    }
    eprintln("客户端已连接 fd=\{client}")
    let up = connect_unix(cstr(upstream))
    if up < 0 {
      eprintln("连接上游失败: \{up}")
      close_fd(client) |> ignore
      continue
    }
    relay(client, up, verbose)
    close_fd(client) |> ignore
    close_fd(up) |> ignore
  }
}
