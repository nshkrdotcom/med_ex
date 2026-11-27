// Reads {:packet, 4} frames of one 20 ms mono 48 kHz PCM16LE frame each and
// writes one Opus packet per frame in the same framing. The first frame written
// is a hello: "med_ex_opus/1 <libopus version>". Any protocol violation exits.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <opus.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

enum { RATE = 48000, FRAME = 960, PCM_BYTES = FRAME * 2, MAX_PACKET = 1275 };
enum { IO_ERROR = -2, IO_TRUNCATED = -1, IO_EOF = 0, IO_OK = 1 };

static int read_exact(uint8_t *buf, size_t n) {
  size_t offset = 0;
  while (offset < n) {
    ssize_t count = read(STDIN_FILENO, buf + offset, n - offset);
    if (count > 0) offset += (size_t)count;
    else if (count == 0) return offset == 0 ? IO_EOF : IO_TRUNCATED;
    else if (errno != EINTR) return IO_ERROR;
  }
  return IO_OK;
}

static int write_exact(const uint8_t *buf, size_t n) {
  size_t offset = 0;
  while (offset < n) {
    ssize_t count = write(STDOUT_FILENO, buf + offset, n - offset);
    if (count > 0) offset += (size_t)count;
    else if (count == 0 || errno != EINTR) return 0;
  }
  return 1;
}

static int write_frame(const uint8_t *p, uint32_t n) {
  const uint8_t head[4] = {n >> 24, n >> 16, n >> 8, n};
  return write_exact(head, sizeof head) && write_exact(p, n);
}

static int encode(void) {
  int err, result = 0;
  // A closed output is an I/O failure, allowing ordinary cleanup before exit.
  // The parent still independently kills/reaps a stopped or hung codec child.
  if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) return 6;
  OpusEncoder *enc = opus_encoder_create(RATE, 1, OPUS_APPLICATION_AUDIO, &err);
  if (enc == NULL) return 3;
  if (err != OPUS_OK) { result = 3; goto done; }

  char hello[64];
  int n = snprintf(hello, sizeof hello, "med_ex_opus/1 %s", opus_get_version_string());
  if (n < 0 || (size_t)n >= sizeof hello) { result = 3; goto done; }
  if (!write_frame((const uint8_t *)hello, (uint32_t)n)) { result = 2; goto done; }

  for (;;) {
    uint8_t head[4], raw[PCM_BYTES], out[MAX_PACKET];
    opus_int16 pcm[FRAME];
    int status = read_exact(head, sizeof head);
    if (status == IO_EOF) break; // owner closed stdin between frames
    if (status != IO_OK) { result = 4; goto done; }
    uint32_t len = (uint32_t)head[0] << 24 | (uint32_t)head[1] << 16 | (uint32_t)head[2] << 8 | head[3];
    if (len != PCM_BYTES || read_exact(raw, PCM_BYTES) != IO_OK) { result = 4; goto done; }
    for (int i = 0; i < FRAME; i++) {
      uint16_t u = (uint16_t)raw[2 * i] | ((uint16_t)raw[2 * i + 1] << 8);
      int32_t value = u <= INT16_MAX ? (int32_t)u : (int32_t)u - 65536;
      pcm[i] = (opus_int16)value;
    }
    opus_int32 r = opus_encode(enc, pcm, FRAME, out, MAX_PACKET);
    if (r < 1) { result = 5; goto done; }
    if (!write_frame(out, (uint32_t)r)) { result = 2; goto done; }
  }

done:
  opus_encoder_destroy(enc);
  return result;
}

// The port process owns the codec child until waitpid reaps it. Watching the
// output pipe catches BEAM shutdown even if libopus hangs or the child stops.
// A separate pipe signals child exit without racing SIGCHLD against poll.
int main(void) {
  int life[2];
  // Keep the PID reserved until we reap it, even if the caller ignored SIGCHLD.
  if (signal(SIGCHLD, SIG_DFL) == SIG_ERR || pipe(life) < 0) return 6;
#ifdef __linux__
  pid_t supervisor = getpid();
#endif
  pid_t child = fork();
  if (child < 0) return 6;
  if (child == 0) {
#ifdef __linux__
    // The parent can die before or during setup. Arm first, then check identity.
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 || getppid() != supervisor) _exit(6);
#endif
    close(life[0]);
    return encode();
  }

  close(life[1]);
  close(STDIN_FILENO);
  struct pollfd watched[] = {{STDOUT_FILENO, 0, 0}, {life[0], 0, 0}};
  int ready;
  do {
    ready = poll(watched, 2, -1);
  } while (ready < 0 && errno == EINTR);
  if (ready < 0 || watched[0].revents) kill(child, SIGKILL);

  int status;
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 6;
  }
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
