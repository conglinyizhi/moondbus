///|
/// 演示：async 程序误在事件循环线程上调用阻塞 API 会怎样。
///
/// 期望：立刻打印中止原因并退出，而不是卡在那里。
fn main {
  @dbus.declare_async_thread()
  let conn = match @dbus.connect_bus() {
    Ok(c) => c
    Err(e) => {
      eprintln("连不上总线: \{e}")
      return
    }
  }
  eprintln("准备在事件循环线程上调用 recv_message…")
  let _ = @dbus.recv_message(conn)
  eprintln("如果没有中止，说明守卫没生效")
}
