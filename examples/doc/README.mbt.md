# moondbus — 可编译示例

这些 `mbt check` 块会被 `moon check` / `moon test` 真实验证，保证文档与实际 API 一致。

## 编码一段方法调用

```mbt check
///|
test "build a method call message" {
  let body = @dbus.build_variant_string("hello")
  let msg = @dbus.build_method_call(
    "com.example.Service",
    "/com/example/Object",
    "com.example.Interface",
    "Ping",
    body,
    "v",
    1,
  )
  assert_true(msg.length() > 0)
}
```

## 服务端分发（Server 抽象）

`Server` 负责连接 / 注册 / 收消息 / 回复，只用关心你的分发逻辑：

```mbt check
///|
test "server dispatch" {
  let r = dispatch_ping("com.example", "Ping")
  if r is Some(reply) {
    assert_eq(reply.signature, "v")
  } else {
    fail("expected reply")
  }
}

///|
/// 模拟服务分发：Ping 返回 pong，其它不回。
fn dispatch_ping(iface : String, member : String) -> @dbus.Reply? {
  if iface == "com.example" && member == "Ping" {
    Some(@dbus.Reply::make(@dbus.build_variant_string("pong"), "v"))
  } else {
    None
  }
}
```

## 编码 a{sv} 字典（托盘属性等）

```mbt check
///|
test "encode a{sv} dictionary" {
  let e = @dbus.Encoder::new()
  e.array_with(8, fn(dict) {
    dict.struct_with(fn(kv) {
      kv.string("Id")
      kv.variant_string("my-app")
    })
    dict.struct_with(fn(kv) {
      kv.string("Status")
      kv.variant_string("Active")
    })
  })
  let bytes = e.finish()
  assert_true(bytes.length() > 0)
}
```

## 解析一条消息头部

```mbt check
///|
test "parse header fields" {
  // 用 build_method_call 造一条消息，再解析它的 header 字段
  let body = @dbus.build_variant_string("x")
  let msg = @dbus.build_method_call(
    "com.example.Service",
    "/com/example/Object",
    "com.example.Interface",
    "Ping",
    body,
    "v",
    1,
  )
  let fields = @dbus.parse_header_fields(msg)
  match fields.interface {
    Some(i) => assert_eq(i, "com.example.Interface")
    None => fail("no interface parsed")
  }
  match fields.member {
    Some(m) => assert_eq(m, "Ping")
    None => fail("no member parsed")
  }
}
```
