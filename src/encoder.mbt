///|
/// 通用 D-Bus 值编码器。
///
/// D-Bus 的 wire format 对每种类型有固定的对齐要求，手工拼字节很容易错。
/// Encoder 把对齐和长度前缀封装起来，让上层能拼出任意复杂的结构
/// （如 dbusmenu 的 `(ia{sv}av)`）。
///
/// 注意：对齐是相对于**整条消息**的起点。若你在独立的 Encoder 里构造
/// 一段将被嵌入消息 body 的数据，请确保 body 起点本身是 8 字节对齐的
/// （`build_method_return` / `build_signal` 已保证这一点）。
pub struct Encoder {
  buf : Buffer
  base : Int // 这段数据在整条消息中的起始偏移（用于正确对齐）
}

///|
/// 新建一个编码器。
pub fn Encoder::new() -> Encoder {
  { buf: Buffer::Buffer(), base: 0, }
}

///|
/// 新建一个编码器，声明它在整条消息中的起始偏移。
/// 编码嵌套结构（数组元素等）时必须用它，否则对齐会错位。
pub fn Encoder::new_at(base : Int) -> Encoder {
  { buf: Buffer::Buffer(), base, }
}

///|
/// 当前绝对偏移（消息起点算起）。
pub fn Encoder::pos(self : Encoder) -> Int {
  self.base + self.buf.length()
}

///|
/// 当前已写入的字节数（用于计算数组长度）。
pub fn Encoder::len(self : Encoder) -> Int {
  self.buf.length()
}

///|
/// 补零对齐到 n 字节边界。
pub fn Encoder::align(self : Encoder, n : Int) -> Unit {
  while (self.base + self.buf.length()) % n != 0 {
    self.buf.write_byte(0)
  }
}

///|
/// 写单个字节（y）。
pub fn Encoder::byte(self : Encoder, b : Byte) -> Unit {
  self.buf.write_byte(b)
}

///|
/// 写原始字节序列（不做对齐）。
pub fn Encoder::raw(self : Encoder, b : Bytes) -> Unit {
  self.buf.write_bytes(b)
}

///|
/// 写 uint32（u），自动对齐到 4。
pub fn Encoder::u32(self : Encoder, v : Int) -> Unit {
  self.align(4)
  let mut i = 0
  while i < 4 {
    self.buf.write_byte(((v >> (8 * i)) & 0xFF).to_byte())
    i = i + 1
  }
}

///|
/// 写 int32（i），编码同 u32。
pub fn Encoder::i32(self : Encoder, v : Int) -> Unit {
  self.u32(v)
}

///|
/// 写布尔（b）：D-Bus 用 uint32 表示。
pub fn Encoder::bool(self : Encoder, v : Bool) -> Unit {
  self.u32(if v { 1 } else { 0 })
}

///|
/// 写字符串（s / o）：对齐 4 + uint32 长度 + 内容 + NUL。
pub fn Encoder::string(self : Encoder, s : String) -> Unit {
  let bs = @utf8.encode(s)
  self.u32(bs.length())
  self.buf.write_bytes(bs)
  self.buf.write_byte(0)
}

///|
/// 写签名（g）：单字节长度 + 内容 + NUL（注意不是 uint32）。
pub fn Encoder::signature(self : Encoder, s : String) -> Unit {
  let bs = @utf8.encode(s)
  self.buf.write_byte(bs.length().to_byte())
  self.buf.write_bytes(bs)
  self.buf.write_byte(0)
}

///|
/// 写一个持有字符串的 variant（v）。
pub fn Encoder::variant_string(self : Encoder, s : String) -> Unit {
  self.signature("s")
  self.string(s)
}

///|
/// 写一个持有布尔的 variant（v）。
pub fn Encoder::variant_bool(self : Encoder, v : Bool) -> Unit {
  self.signature("b")
  self.bool(v)
}

///|
/// 写一个持有 int32 的 variant（v）。
pub fn Encoder::variant_i32(self : Encoder, v : Int) -> Unit {
  self.signature("i")
  self.i32(v)
}

///|
/// 写一个持有任意类型的 variant（v）。
/// `signature` 是持有的类型签名，`f` 用当前 Encoder 写那个类型的值。
/// 用于无法用预置 variant_xxx 覆盖的类型（如 `a(iiibay)`、自定义 struct）。
pub fn Encoder::variant_with(
  self : Encoder,
  signature : String,
  f : (Encoder) -> Unit,
) -> Unit {
  self.signature(signature)
  f(self)
}

///|
/// 取出编码结果。
pub fn Encoder::finish(self : Encoder) -> Bytes {
  self.buf.to_bytes()
}

///|
/// 把一段已编码的数据作为「数组」写入：uint32 字节长度 + 元素对齐 + 内容。
///
/// `elem_align` 是数组**元素**的对齐要求（如 dict entry 与 struct 是 8，
/// 字符串是 4）。DBus 规定长度前缀之后要先对齐到元素边界，
/// 且该填充**不计入**长度。
pub fn Encoder::array(
  self : Encoder,
  elem_align : Int,
  content : Bytes,
) -> Unit {
  self.u32(content.length())
  self.align(elem_align)
  self.buf.write_bytes(content)
}

///|
/// 编码一个数组，内容由回调在**正确的绝对偏移**下写入。
///
/// 这是编码嵌套结构的推荐方式：回调拿到的 Encoder 已经知道自己
/// 将落在消息的哪个位置，因此内部的对齐都是对的。
pub fn Encoder::array_with(
  self : Encoder,
  elem_align : Int,
  f : (Encoder) -> Unit,
) -> Unit {
  // 推算数组内容的起始绝对偏移：
  //   当前位置 -> 对齐到 4（长度前缀） -> +4 -> 对齐到元素边界
  let mut pos = self.pos()
  while pos % 4 != 0 {
    pos = pos + 1
  }
  pos = pos + 4
  while pos % elem_align != 0 {
    pos = pos + 1
  }
  let inner = Encoder::new_at(pos)
  f(inner)
  let content = inner.finish()
  self.u32(content.length())
  self.align(elem_align)
  self.buf.write_bytes(content)
}

///|
/// 编码一个 struct（8 字节对齐），内容由回调写入。

///|
/// 把一段已编码的数据以 struct 形式写入，按 8 字节对齐。
pub fn Encoder::struct_with(self : Encoder, f : (Encoder) -> Unit) -> Unit {
  self.align(8)
  let inner = Encoder::new_at(self.pos())
  f(inner)
  self.buf.write_bytes(inner.finish())
}

///|
/// 以指定对齐写一个 struct（D-Bus 里 struct 对齐 = 成员最大对齐）。
/// 默认 struct_with 用 8；当成员只有 int32 等对齐 4 的类型（如 `(iiibay)`）
/// 时请用这个方法 + 4，避免多 pad 字节导致布局错位。
pub fn Encoder::struct_with_align(
  self : Encoder,
  align : Int,
  f : (Encoder) -> Unit,
) -> Unit {
  self.align(align)
  let inner = Encoder::new_at(self.pos())
  f(inner)
  self.buf.write_bytes(inner.finish())
}

///|
/// 写一个持有对象路径的 variant（v 里装 o）。
/// 对象路径的线格式与字符串相同，只是签名不同。
pub fn Encoder::variant_object_path(self : Encoder, path : String) -> Unit {
  self.signature("o")
  self.string(path)
}
