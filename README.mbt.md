# moondbus

Pure MoonBit implementation of the **D-Bus** protocol for Linux desktops.

Connect to the session bus, authenticate, call methods on other services, and
export your own objects — all in MoonBit. Only ~40 lines of C are used for the
raw unix-domain socket syscalls; **the entire D-Bus wire protocol is written in MoonBit**.

The `mbt check` examples below are **compiled and run by `moon check` / `moon test`**,
so the documented API stays true to the code. Extra compiled snippets are in
`examples/doc`.

## Why

Existing MoonBit desktop packages bind to C libraries (GIO, libdbus, tray helpers).
This package implements the protocol itself, so you get:

- No dependency on `libdbus`, `glib` or `gio`
- Full control over the wire format
- A base you can build higher-level desktop integrations on

## Features

- **Connection & authentication** — unix socket, SASL `EXTERNAL`, `BEGIN` handshake
- **Message codec** — little-endian header/body encoding with correct alignment
  (including the `g` signature type's single-byte length and 8-byte struct alignment)
- **Client side** — `Hello`, `RequestName`, arbitrary method calls
- **Server side** — `Server` abstraction with a reusable `serve()` loop: connect,
  register a name, receive `METHOD_CALL`s, dispatch to your handler, and reply
  automatically. The `moonsni` tray runs on this loop.
- **Server primitives** — `parse_header_fields`, `build_method_return`, encode
  `variant` and `a{sv}` dictionaries
- **Signals** — emit `SIGNAL` messages
- **Value encoder** — offset-aware `Encoder` for building nested types
  (`a{sv}`, `(ia{sv}av)`, variants, object paths) with correct alignment
- **Message framing** — reads exactly one message at a time from the stream

## Install

```
moon add conglinyizhi/moondbus
```

Add to your `moon.pkg`:

```
import {
  "conglinyizhi/moondbus/src" @dbus,
}
supported_targets = "+native"
```

## Quick start

Encode and parse messages — pure, no connection needed:

```mbt check
///|
test "build and parse a method call" {
  // 构造一条方法调用消息
  let body = @dbus.build_variant_string("hello")
  let msg = @dbus.build_method_call(
    "com.example.Service", "/com/example/Object", "com.example.Interface", "Ping",
    body, "v", 1,
  )
  assert_true(msg.length() > 0)

  // 解析它的 header 字段
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

### Calling a live service

A real connection and `Hello` handshake (runs against the bus, so it's shown not
compiled):

```mbt nocheck
///|
fn main {
  match @dbus.connect_bus() {
    Err(e) => println("connect failed: \{e}")
    Ok(conn) => {
      match @dbus.hello(conn) {
        Err(e) => println("hello failed: \{e}")
        Ok(name) => println("our unique name: \{name}") // e.g. ":1.448"
      }

      // Ask the bus who owns a well-known name
      match
        @dbus.call_with_string(
          conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
          "GetNameOwner", "org.kde.StatusNotifierWatcher", 2,
        ) {
        Err(e) => println("call failed: \{e}")
        Ok(m) =>
          match @dbus.read_dbus_string(m.body, 0) {
            Some(owner) => println("owner: \{owner}")
            None => println("no owner")
          }
      }
      @dbus.close(conn)
    }
  }
}
```

## API overview

### Connection

| Function | Purpose |
|---|---|
| `connect_bus()` | Connect to the session bus and complete SASL authentication |
| `close(conn)` | Close the connection |
| `send_raw(conn, bytes)` | Write raw bytes |
| `recv_raw(conn, len)` | Read up to `len` bytes |
| `recv_message(conn)` | Read exactly one complete D-Bus message |
| `getpid()` | Current process id (useful for well-known names) |

### Calls

| Function | Purpose |
|---|---|
| `hello(conn)` | The mandatory `Hello` handshake; returns your unique name |
| `call(conn, dest, path, iface, member, body, sig, serial)` | Full method call |
| `call_simple(...)` | Method call with no arguments |
| `call_with_string(...)` | Method call with a single string argument |
| `request_name(conn, name, flags, serial)` | Claim a well-known bus name |

### Messages

| Function | Purpose |
|---|---|
| `build_method_call(...)` | Encode a `METHOD_CALL` |
| `build_method_return(...)` | Encode a `METHOD_RETURN` reply |
| `parse_message(bytes)` | Decode type / serial / body |
| `parse_header_fields(bytes)` | Decode path / interface / member / sender / … |
| `read_dbus_string(body, off)` | Read a string out of a message body |
| `build_variant_string(value)` | Encode a `v` holding a string |
| `build_dict_sv(entries)` | Encode an `a{sv}` dictionary |

### Encoding values

D-Bus alignment is relative to the **start of the message**, which makes hand-
rolling nested structures error-prone. `Encoder` tracks that offset for you.

| Method | Type |
|---|---|
| `Encoder::new()` / `new_at(base)` | Create; `new_at` declares the absolute offset |
| `byte` / `u32` / `i32` / `bool` | `y` / `u` / `i` / `b` |
| `string` / `signature` | `s`,`o` / `g` (single-byte length!) |
| `variant_string` / `variant_bool` / `variant_i32` / `variant_object_path` | `v` |
| `array_with(align, f)` | Array; the callback writes elements at the right offset |
| `struct_with(f)` | Struct (8-byte aligned) |
| `align(n)` / `pos()` / `finish()` | Manual control |

Building `a{sv}` (a property dictionary):

```mbt check
///|
test "encode a{sv} dictionary" {
  let e = @dbus.Encoder::new()
  e.array_with(8, fn(dict) {
    dict.struct_with(fn(kv) {
      kv.string("Title")
      kv.variant_string("My App")
    })
    dict.struct_with(fn(kv) {
      kv.string("Menu")
      kv.variant_object_path("/MenuBar")
    })
  })
  let body = e.finish()
  assert_true(body.length() > 0)
}
```

### Emitting signals

```mbt check
///|
test "build an a{sv} body for a signal" {
  // encode_layout 需要的 body (u ui) 示例：用 build_body_uu 构造
  let body = @dbus.build_body_uu(2, 0)
  assert_true(body.length() > 0)
}
```

## Implementing a D-Bus service

The high-level way is the `Server` abstraction, which owns the connect / name
registration / receive / reply loop and just calls your handler for each
`METHOD_CALL`:

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
    None // unknown method: no reply
  }
}
```

If you prefer the raw primitives, `parse_header_fields` plus `build_method_return`
are enough. The important detail: **a reply must set `destination` to the
requester's `sender`**, otherwise the bus cannot route it back.

See [moonsni](https://github.com/conglinyizhi/moonsni) for a complete service
implementation (a KDE system tray icon).

## Status & limitations

Works today:

- Session bus over unix socket, `EXTERNAL` auth
- Method calls with `s`, `su` bodies
- Replies with `v`, `a{sv}`, and arbitrary nested types via `Encoder`
- Emitting signals
- Object export — verified against the StatusNotifierItem and
  com.canonical.dbusmenu specs (see [moonsni](https://github.com/conglinyizhi/moonsni))

Not implemented yet:

- System bus address transports other than filesystem Unix sockets
- Receiving / matching signals (`AddMatch`)
- Decoding arbitrary types (only strings and u32 are decoded today)
- 64-bit integers, doubles, file descriptors
- Non-EXTERNAL authentication mechanisms

Contributions welcome.

## Platform

Linux only, native backend (`preferred_target = "native"`).
Requires a C compiler; set `MOON_CC=gcc` if the toolchain cannot find one.

**Tested only on the author's local machine** — an Arch-based Linux system with
the session bus over a unix socket. This is a single-environment verification:

- The session bus address is read from `DBUS_SESSION_BUS_ADDRESS` when set;
  otherwise the library falls back to `/run/user/<current uid>/bus`.
- Filesystem Unix socket addresses and percent-encoded paths are supported.
- **Not** tested against the system bus, abstract Unix sockets, a different
  session bus address, or a differently-configured `dbus-daemon`.
- **Not** tested on other platforms: no Windows (D-Bus uses TCP loopback there,
  not unix sockets) or macOS testing has been done.
- The wire codec is exercised by unit tests (alignment / round-trips / robust
  parsing) but **not** validated against a third-party D-Bus implementation's
  byte-for-byte output.

If you use this against a different bus setup and hit a problem, it would be
valuable to report it.

## License

Apache-2.0
