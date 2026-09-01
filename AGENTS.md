# moondbus AGENTS.md

This is a [MoonBit](https://docs.moonbitlang.com) project — a **pure MoonBit
D-Bus protocol library**. No GLib/GIO/libdbus. The entire wire protocol is
written in MoonBit; only ~40 lines of C (`src/stub.c`) handle the raw unix socket
syscalls.

## What this library is

The low-level D-Bus layer that other desktop integrations build on. It provides:

- **Connection** — session-bus unix socket + SASL `EXTERNAL` auth + `BEGIN`.
- **Client calls** — `Hello`, `RequestName`, arbitrary `call(...)`.
- **Server** — `Server` abstraction (`serve()` loop) for receiving `METHOD_CALL`s
  and replying. `moonsni`'s tray runs on this loop.
- **Codec** — `Encoder` (offset-aware) + message build/parse + header fields.
- **Signals** — `emit_signal`.

## Project structure

```
moondbus/
├── moon.pkg              # 根聚合包（文档编译环境；本身不导出符号）
├── README.mbt.md         # 主文档，含 mbt check 示例（被验证）
├── src/
│   ├── conn.mbt          # 连接/认证/发送/接收（unix socket + SASL）
│   ├── message.mbt       # 消息 wire 编解码（方法调用/返回/信号 header）
│   ├── encoder.mbt       # 偏移感知 Encoder（对齐/嵌套类型）
│   ├── call.mbt          # 高层客户端调用 API
│   ├── server.mbt        # 服务端 Server 抽象（serve 循环/分发）
│   └── stub.c            # C stub：unix socket syscalls（唯一 FFI）
├── examples/doc/         # 可编译示例集（mbt check）
```

子包 import 路径：`conglinyizhi/moondbus/src`（别名 `@dbus`）。

## Wire protocol details (坑，必读)

1. **对齐相对于消息起点**，不是相对于字段。`Encoder` 必须知道绝对偏移
   （`new_at(base)`），嵌套结构（struct/array/dict-entry）对齐到 8 字节。
2. **`String` 在 MoonBit 是 UTF-16**，直接 `+` 拼接会引入 `\x00`——**D-Bus 消息
   必须用 `Encoder` 字节级构建**。
3. **`signature` 类型 (g) 是单字节长度** + 内容 + NUL（不是 u32 长度，跟 `s` 不同）。
4. **variant (v) = 签名 (g) + 值**。预置 `variant_string/bool/i32/object_path`；
   任意类型用 `variant_with(signature, fn)`。
5. **method return 的 `destination` 必须 = 请求方 sender**，否则总线无法路由。
6. 读取 `i32` 时注意有符号：`read_le_u32_at` 读 u32，转有符号要处理补码
   （`>= 0x80000000` 时减 `2^32`，但 MoonBit Int 是 32 位，用 `-(0xFFFFFFFF - u + 1)`）。

## C stub conventions

- `src/stub.c` 的 C 函数名用 `moonbit_dbus_*` 前缀（`moonbit_dbus_unix_connect` 等）。
- `extern "c"` 传 `Bytes` 指针必须 `#borrow(param)` **单独一行**（内联会报 0055）。
- 依赖 `src/moon.pkg` 的 `"native-stub": ["stub.c"]` + `supported_targets = "+native"`。

## Coding convention

- MoonBit 块风格，`///|` 分隔。
- 跨包调用必须 `@dbus.fn()`；同包 `_test.mbt`（黑盒）对被测包 pub 符号**不带前缀**。
- 枚举变体/结构字段跨包构造需要 `pub(all)`。
- `Connection` / `Message` / `HeaderFields` 字段对外**只读**（pub struct 字段默认可读）。
- 需要跨包构造的类型（如 `Reply`）提供构造函数或 `pub(all)`。

## Testing

- `src/protocol_test.mbt` 是协议单元测试（Encoder 对齐、编解码往返、header 解析、
  畸形输入健壮性、数组/字典、Server 类型）。**纯逻辑，不连总线**。
- `README.mbt.md` 的 `mbt check` 块会被执行——改公共 API 时同步更新。
- 运行 `MOON_CC=gcc moon test --target native`。
- 断言用 `assert_eq` / `assert_true`。

## Tooling

- `moon fmt` / `moon info`（生成 `.mbti`，检查公共 API diff）。
- 提交前：`moon info && moon fmt`，再 `moon test --target native`。
- `src/pkg.generated.mbti` 纳入版本控制。

## Build / run

```
MOON_CC=gcc moon build --target native
```

需要 `MOON_CC=gcc`（若工具链找不到 C 编译器）。
