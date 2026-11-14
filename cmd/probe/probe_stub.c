/* probe 工具用的最小 socket 支撑：监听、accept、poll、读写、连接。
 * 这些只是调试工具的需要，不进核心库。 */
#include <moonbit.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

MOONBIT_FFI_EXPORT
int moonbit_probe_listen(const char *path, int32_t backlog) {
  if (!path) return -EINVAL;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -errno;
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  size_t n = strlen(path);
  if (n >= sizeof(addr.sun_path)) { close(fd); return -ENAMETOOLONG; }
  memcpy(addr.sun_path, path, n + 1);
  unlink(path);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    int e = errno; close(fd); return -e;
  }
  if (listen(fd, backlog) < 0) { int e = errno; close(fd); return -e; }
  return fd;
}

MOONBIT_FFI_EXPORT
int moonbit_probe_accept(int32_t fd) {
  int c = accept(fd, NULL, NULL);
  if (c < 0) return -errno;
  return c;
}

MOONBIT_FFI_EXPORT
int moonbit_probe_connect(const char *path) {
  if (!path) return -EINVAL;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -errno;
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  size_t n = strlen(path);
  if (n >= sizeof(addr.sun_path)) { close(fd); return -ENAMETOOLONG; }
  memcpy(addr.sun_path, path, n + 1);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    int e = errno; close(fd); return -e;
  }
  return fd;
}

/* 返回位掩码：1 = a 可读，2 = b 可读；0 超时；负数是 -errno。 */
MOONBIT_FFI_EXPORT
int moonbit_probe_poll2(int32_t a, int32_t b, int32_t timeout_ms) {
  struct pollfd fds[2];
  fds[0].fd = a; fds[0].events = POLLIN; fds[0].revents = 0;
  fds[1].fd = b; fds[1].events = POLLIN; fds[1].revents = 0;
  int r = poll(fds, 2, timeout_ms);
  if (r < 0) return -errno;
  int mask = 0;
  if (fds[0].revents) mask |= 1;
  if (fds[1].revents) mask |= 2;
  return mask;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_probe_read(int32_t fd, char *buf, int32_t len) {
  ssize_t n = read(fd, buf, (size_t)len);
  if (n < 0) return (int32_t)-errno;
  return (int32_t)n;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_probe_write(int32_t fd, const char *buf, int32_t len) {
  ssize_t n = write(fd, buf, (size_t)len);
  if (n < 0) return (int32_t)-errno;
  return (int32_t)n;
}

MOONBIT_FFI_EXPORT
int moonbit_probe_close(int32_t fd) {
  close(fd);
  return 0;
}

/* 追加写文件：把一行日志写进文件。返回写入字节数，负数是 -errno。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_probe_append(const char *path, const char *data, int32_t len) {
  int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0) return (int32_t)-errno;
  ssize_t n = write(fd, data, (size_t)len);
  int e = errno;
  close(fd);
  if (n < 0) return (int32_t)-e;
  return (int32_t)n;
}
