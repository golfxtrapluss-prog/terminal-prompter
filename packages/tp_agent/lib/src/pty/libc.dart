/// Thin `dart:ffi` bindings to the libc calls needed for PTY handling.
///
/// Linux only. Symbols are resolved from the running process (libc is always
/// loaded), so no library path is needed. Constants are identical on
/// linux-x64 and linux-arm64 (docs/02, ADR-003).
library;

import 'dart:ffi';

/// `struct winsize` from `<sys/ioctl.h>`.
final class WinSize extends Struct {
  @Uint16()
  external int wsRow;

  @Uint16()
  external int wsCol;

  @Uint16()
  external int wsXPixel;

  @Uint16()
  external int wsYPixel;
}

/// `struct pollfd` from `<poll.h>`.
final class PollFd extends Struct {
  @Int32()
  external int fd;

  @Int16()
  external int events;

  @Int16()
  external int revents;
}

// <fcntl.h>
const int oRdwr = 0x2;
const int oNoctty = 0x100;
const int oNonblock = 0x800;
const int oCloexec = 0x80000;

// <sys/ioctl.h>
const int tiocgwinsz = 0x5413;
const int tiocswinsz = 0x5414;

// <poll.h>
const int pollIn = 0x1;
const int pollErr = 0x8;
const int pollHup = 0x10;
const int pollNval = 0x20;

// <errno.h>
const int eintr = 4;
const int eio = 5;
const int eagain = 11;

// <signal.h>
const int sighup = 1;
const int sigint = 2;
const int sigkill = 9;
const int sigterm = 15;

@Native<Int Function(Int)>(symbol: 'posix_openpt')
external int posixOpenpt(int flags);

@Native<Int Function(Int)>(symbol: 'grantpt')
external int grantpt(int fd);

@Native<Int Function(Int)>(symbol: 'unlockpt')
external int unlockpt(int fd);

@Native<Int Function(Int, Pointer<Char>, Size)>(symbol: 'ptsname_r')
external int ptsnameR(int fd, Pointer<Char> buf, int bufLen);

/// `ioctl` is variadic in C; this binding is specialised for `TIOCSWINSZ` /
/// `TIOCGWINSZ` with a `struct winsize*` argument.
@Native<Int Function(Int, UnsignedLong, VarArgs<(Pointer<WinSize>,)>)>(
  symbol: 'ioctl',
)
external int ioctlWinSize(int fd, int request, Pointer<WinSize> ws);

@Native<IntPtr Function(Int, Pointer<Uint8>, Size)>(symbol: 'read')
external int read(int fd, Pointer<Uint8> buf, int count);

@Native<IntPtr Function(Int, Pointer<Uint8>, Size)>(symbol: 'write')
external int write(int fd, Pointer<Uint8> buf, int count);

@Native<Int Function(Int)>(symbol: 'close')
external int close(int fd);

@Native<Int Function(Pointer<PollFd>, UnsignedLong, Int)>(symbol: 'poll')
external int poll(Pointer<PollFd> fds, int nfds, int timeoutMs);

@Native<Int Function(Pointer<Int32>, Int)>(symbol: 'pipe2')
external int pipe2(Pointer<Int32> fds, int flags);

@Native<Int Function(Int, Int)>(symbol: 'kill')
external int kill(int pid, int signal);

@Native<Pointer<Int32> Function()>(symbol: '__errno_location')
external Pointer<Int32> _errnoLocation();

/// The calling thread's `errno`. Read it immediately after a failed call.
int get errno => _errnoLocation().value;
