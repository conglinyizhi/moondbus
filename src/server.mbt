///|
/// moondbus：服务端抽象 —— 常驻接收方法调用并回复。
///
/// D-Bus 上的「服务」有两个方向：
///  - 主动：call / emit_signal（已有）
///  - 被动：接收别的方法调用并回复（本文件）
///
/// Server 封装「connect + hello + 循环收消息 + 分发」，
/// 让上层（托盘、MPRIS 播放器、自定义服务）不用手写 recv/parse/reply。
///
/// 典型用法：
///   let s = @dbus.Server::connect().unwrap()
///   s.hello().unwrap()
///   s.serve(fn(s, ctx) {
///     match ctx.iface, ctx.member {
///       "com.example" , "Ping" => Some({ body: ..., signature: "s" })
///       _ => None   // 不认识的方法，不回复
///     }
///   })

///|
/// 一次方法调用的上下文：接口、方法名、发送方、本次调用序列号、body。
pub struct DispatchCtx {
  iface : String
  member : String
  sender : String
  reply_serial : Int
  body : Bytes
}

///|
/// 要回复的内容：body（已编码）+ 签名。
pub(all) struct Reply {
  body : Bytes
  signature : String
}

///|
/// 构造一个回复。
pub fn Reply::make(body : Bytes, signature : String) -> Reply {
  { body, signature }
}

///|
/// 一个 D-Bus 服务：持有连接与回复序列号。
pub struct Server {
  conn : Connection
  mut serial : Int
}

///|
/// 连接 session bus 并返回一个 Server。
pub fn Server::connect() -> Result[Server, Int] {
  match connect_bus() {
    Err(e) => Err(e)
    Ok(conn) => Ok({ conn, serial: 100 })
  }
}

///|
/// 连接后发 Hello 握手。返回响应的唯一名字（bus name）。
pub fn Server::hello(self : Server) -> Result[String, Int] {
  hello(self.conn)
}

///|
/// 注册一个名字（如 org.kde.StatusNotifierItem-<pid>-1）。
pub fn Server::request_name(
  self : Server,
  name : String,
  flags : Int,
) -> Result[Int, Int] {
  request_name(self.conn, name, flags, 2)
}

///|
/// 发起一次带字符串参数的方法调用（常用于注册服务）。
pub fn Server::call_with_string(
  self : Server,
  destination : String,
  path : String,
  iface : String,
  member : String,
  arg : String,
  flags : Int,
) -> Result[Message, Int] {
  call_with_string(self.conn, destination, path, iface, member, arg, self.serial)
}

///|
/// 发一条信号（用本服务器的连接与递增序列号）。
pub fn Server::emit_signal(
  self : Server,
  path : String,
  iface : String,
  name : String,
  body : Bytes,
  signature : String,
) -> Result[Int, Int] {
  let r = emit_signal(self.conn, path, iface, name, body, signature, self.serial)
  self.serial = self.serial + 1
  r
}

///|
/// 常驻事件循环：收消息，收到 METHOD_CALL(1) 时交给 dispatch。
///
/// dispatch 收到 (server, ctx)，返回 Some(Reply) 时自动回复调用方；
/// 返回 None 则不回复（如未知方法）。
///
/// 除 METHOD_CALL 外的消息（信号、方法返回）会被跳过。
/// 循环直到连接关闭。
pub fn Server::serve(
  self : Server,
  dispatch : (Server, DispatchCtx) -> Option[Reply],
) -> Unit {
  let mut running = true
  while running {
    match recv_message(self.conn) {
      Err(_) => running = false
      Ok(raw) =>
        match parse_message(raw) {
          None => ()
          Some(m) =>
            if m.msg_type.to_int() == 1 {
              let fields = parse_header_fields(raw)
              let ctx = DispatchCtx::of(m, fields)
              match dispatch(self, ctx) {
                Some(reply) => {
                  self.reply(ctx, reply)
                }
                None => ()
              }
            }
        }
    }
  }
}

///|
/// 给调用方回一条 METHOD_RETURN。
fn Server::reply(self : Server, ctx : DispatchCtx, reply : Reply) -> Unit {
  let dest = ctx.sender
  let body_text =
    if reply.signature == "" {
      Bytes::makei(0, fn(_) { 0 })
    } else {
      reply.body
    }
  let msg = build_method_return(dest, ctx.reply_serial, body_text, reply.signature, self.serial)
  let _ = send_raw(self.conn, msg)
  self.serial = self.serial + 1
}

///|
/// 从消息构造 DispatchCtx。
fn DispatchCtx::of(m : Message, fields : HeaderFields) -> DispatchCtx {
  let iface = match fields.interface {
    Some(s) => s
    None => ""
  }
  let member = match fields.member {
    Some(s) => s
    None => ""
  }
  let sender = match fields.sender {
    Some(s) => s
    None => ""
  }
  { iface, member, sender, reply_serial: m.serial, body: m.body }
}
