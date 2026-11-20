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

#if !defined(__linux__)
#error "moondbus 目前只支持 Linux：它依赖 D-Bus 会话总线（unix socket + EXTERNAL 认证）。Windows 上的 D-Bus 走 TCP 环回，macOS 也没有这个头文件组合，都还没有实现。"
#endif

#include <moonbit.h>
#include <sys/socket.h>
#include <poll.h>
#include <sys/un.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <errno.h>
#include <string.h>

// 连接 Unix domain socket（DBus session bus 用）。返回 fd，失败返回 -errno。
MOONBIT_FFI_EXPORT
int moonbit_dbus_unix_connect(const char *path) {
  if (!path) return -EINVAL;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -errno;
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  size_t plen = strlen(path);
  if (plen >= sizeof(addr.sun_path)) {
    close(fd);
    return -ENAMETOOLONG;
  }
  memcpy(addr.sun_path, path, plen + 1);
  int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
  if (r < 0) {
    int e = errno;
    close(fd);
    return -e;
  }
  return fd;
}

// 关闭 fd
MOONBIT_FFI_EXPORT
int moonbit_dbus_close(int fd) {
  return close(fd);
}

// 读 fd 到缓冲区，返回读到的字节数（0=EOF, 负=errno）
MOONBIT_FFI_EXPORT
long moonbit_dbus_read(int fd, char *buf, unsigned long len) {
  ssize_t n = read(fd, buf, len);
  if (n < 0) return -errno;
  return (long)n;
}

// 写缓冲区到 fd，返回写入字节数（负=errno）
MOONBIT_FFI_EXPORT
long moonbit_dbus_write(int fd, const char *buf, unsigned long len) {
  ssize_t n = write(fd, buf, len);
  if (n < 0) return -errno;
  return (long)n;
}

// 返回当前 uid
MOONBIT_FFI_EXPORT
unsigned int moonbit_dbus_getuid(void) {
  return (unsigned int)getuid();
}

// 返回当前进程 pid
MOONBIT_FFI_EXPORT
int moonbit_dbus_getpid(void) {
  return (int)getpid();
}

/* 当前线程 id，用来识别「这条线程是不是事件循环那条」。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_dbus_thread_id(void) {
  return (int32_t)syscall(SYS_gettid);
}

/* 等 fd 可读：返回 1 可读、0 超时、负数是 -errno。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_dbus_wait_readable(int32_t fd, int32_t timeout_ms) {
  struct pollfd p;
  p.fd = fd;
  p.events = POLLIN;
  p.revents = 0;
  int r = poll(&p, 1, timeout_ms);
  if (r < 0) return (int32_t)-errno;
  return r == 0 ? 0 : 1;
}
