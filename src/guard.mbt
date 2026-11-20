///|
/// 同步阻塞 API 的误用检测。
///
/// moondbus 底下是阻塞 socket：`recv_message` / `send_raw` 会把调用它的那条线程
/// 一直占住。放在普通线程、独立进程里没问题；放在 async 事件循环线程上，整个
/// 程序会静默卡死——不报错、不打日志，只是不再响应任何东西。
///
/// 这里给一个显式的开关：异步程序启动时调一次 `declare_async_thread()`，
/// 之后在事件循环线程上再调阻塞 API 会立刻中止并说明原因，而不是卡在那里。

///|
let async_thread : Ref[Int32] = Ref(0)

///|
extern "c" fn thread_id() -> Int32 = "moonbit_dbus_thread_id"

///|
/// 声明「当前线程是 async 事件循环」。之后这条线程上调用阻塞 API 会直接报错。
///
/// 纯同步程序不要调这个，调了也不会拦自己。
pub fn declare_async_thread() -> Unit {
  async_thread.val = thread_id()
}

///|
/// 有没有声明过事件循环线程。
pub fn async_thread_declared() -> Bool {
  async_thread.val != 0
}

///|
/// 判断这次调用要不要拦：声明过，且当前就在那条线程上。
fn should_guard(declared : Int32, current : Int32) -> Bool {
  declared != 0 && declared == current
}

///|
fn guard_blocking(what : String) -> Unit {
  let declared = async_thread.val
  if should_guard(declared, thread_id()) {
    abort(
      "moondbus: \{what} 是同步阻塞调用，不能跑在 async 事件循环线程上。\n它会把整条事件循环占住，表现为程序静默卡死、不报错。\n正确做法：放到独立线程（C 侧 pthread）或独立进程里；纯同步程序请勿调用 declare_async_thread()。",
    )
  }
}

///|
test "should_guard 只在声明过且在同一个线程时拦" {
  assert_false(should_guard(0, 123))
  assert_true(should_guard(7, 7))
  assert_false(should_guard(7, 8))
}

///|
test "panic 声明事件循环线程后，阻塞调用会中止而不是卡死" {
  declare_async_thread()
  guard_blocking("recv_message")
}
