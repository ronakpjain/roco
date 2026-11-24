#include <poll.h>
#include <unistd.h>

// Return a byte, -1 when there's no input, or EOT once at end of input.
extern "C" int uart_console_input() {
  static bool closed = false;
  if (closed) return -1;

  pollfd input{STDIN_FILENO, POLLIN, 0};
  if (poll(&input, 1, 0) <= 0) return -1;
  if (!(input.revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL))) return -1;

  unsigned char byte;
  const auto count = read(STDIN_FILENO, &byte, 1);
  if (count == 1) return byte;
  if (count < 0 && !(input.revents & (POLLERR | POLLNVAL))) return -1;
  closed = true;
  return 4;
}
