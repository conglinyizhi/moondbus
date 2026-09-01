# moonbit-dbus

Pure MoonBit implementation of the **D-Bus** protocol for Linux desktops.

Connect to the session bus, authenticate, call methods on other services, and
export your own objects — all in MoonBit. Only ~40 lines of C are used for the
raw unix-domain socket syscalls; **the entire D-Bus wire protocol is written in MoonBit**.

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
- **Server side** — parse incoming `METHOD_CALL`, build `METHOD_RETURN` replies,
  encode `variant` and `a{sv}` dictionaries
- **Signals** — emit `SIGNAL` messages
- **Value encoder** — offset-aware `Encoder` for building nested types
  (`a{sv}`, `(ia{sv}av)`, variants, object paths) with correct alignment
- **Message framing** — reads exactly one message at a time from the stream

## Install

```
moon add clyzhi/moonbit-dbus
```

Add to your `moon.pkg`:

```
import {
  "clyzhi/moonbit-dbus/src" @dbus,
}
supported_targets = "+native"
```

## Quick start

Connect, say hello, and query a service:

```
fn main {
  match @dbus.connect_bus() {
    Err(e) => println("connect failed: \{e}")
    Ok(conn) => {
      // Mandatory first call on any D-Bus connection
      match @dbus.hello(conn) {
        Err(e) => println("hello failed: \{e}")
        Ok(name) => println("our unique name: \{name}")   // e.g. ":1.448"
      }

      // Ask the bus who owns a well-known name
      match @dbus.call_with_string(
        conn, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "GetNameOwner",
        "org.kde.StatusNotifierWatcher", 2,
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

```
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
```

### Emitting signals

```
@dbus.emit_signal(
  conn, "/MenuBar", "com.canonical.dbusmenu", "LayoutUpdated",
  @dbus.build_body_uu(revision, 0), "ui", serial,
) |> ignore
```

## Implementing a D-Bus service

`parse_header_fields` plus `build_method_return` are enough to answer incoming
calls. The important detail: **a reply must set `destination` to the requester's
`sender`**, otherwise the bus cannot route it back.

```
let fields = @dbus.parse_header_fields(raw)
let sender = match fields.sender { Some(s) => s; None => "" }
let value = @dbus.build_variant_string("hello")
let reply = @dbus.build_method_return(sender, req.serial, value, "v", my_serial)
let _ = @dbus.send_raw(conn, reply)
```

See [moonbit-sni](https://github.com/conglinyizhi/moonbit-sni) for a complete
service implementation (a KDE system tray icon).

## Status & limitations

Works today:

- Session bus over unix socket, `EXTERNAL` auth
- Method calls with `s`, `su` bodies
- Replies with `v`, `a{sv}`, and arbitrary nested types via `Encoder`
- Emitting signals
- Object export — verified against the StatusNotifierItem and
  com.canonical.dbusmenu specs (see [moonbit-sni](https://github.com/conglinyizhi/moonbit-sni))

Not implemented yet:

- System bus address parsing (the session bus path is currently fixed)
- Receiving / matching signals (`AddMatch`)
- Decoding arbitrary types (only strings and u32 are decoded today)
- 64-bit integers, doubles, file descriptors
- Non-EXTERNAL authentication mechanisms

Contributions welcome.

## Platform

Linux only, native backend (`preferred_target = "native"`).
Requires a C compiler; set `MOON_CC=gcc` if the toolchain cannot find one.

## License

Apache-2.0
