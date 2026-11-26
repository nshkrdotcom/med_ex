// Reads {:packet, 4} frames of one 20 ms mono 48 kHz PCM16LE frame each and
// writes one Opus packet per frame in the same framing. The first frame written
// is a hello: "med_ex_opus/1 <libopus version>". Any protocol violation exits.
#include <opus.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

enum { RATE = 48000, FRAME = 960, PCM_BYTES = FRAME * 2, MAX_PACKET = 1275 };

static int read_exact(uint8_t *buf, size_t n) { return fread(buf, 1, n, stdin) == n; }

static void write_frame(const uint8_t *p, uint32_t n) {
  const uint8_t head[4] = {n >> 24, n >> 16, n >> 8, n};
  if (fwrite(head, 1, 4, stdout) != 4 || fwrite(p, 1, n, stdout) != n || fflush(stdout) != 0)
    exit(2);
}

int main(void) {
  int err;
  OpusEncoder *enc = opus_encoder_create(RATE, 1, OPUS_APPLICATION_AUDIO, &err);
  if (err != OPUS_OK) return 3;

  char hello[64];
  int n = snprintf(hello, sizeof hello, "med_ex_opus/1 %s", opus_get_version_string());
  if (n < 0 || (size_t)n >= sizeof hello) return 3;
  write_frame((const uint8_t *)hello, (uint32_t)n);

  for (;;) {
    uint8_t head[4], raw[PCM_BYTES], out[MAX_PACKET];
    opus_int16 pcm[FRAME];
    if (!read_exact(head, 4)) return 0; // owner closed stdin
    uint32_t len = (uint32_t)head[0] << 24 | (uint32_t)head[1] << 16 | (uint32_t)head[2] << 8 | head[3];
    if (len != PCM_BYTES || !read_exact(raw, PCM_BYTES)) return 4;
    for (int i = 0; i < FRAME; i++) pcm[i] = (opus_int16)(uint16_t)(raw[2 * i] | raw[2 * i + 1] << 8);
    opus_int32 r = opus_encode(enc, pcm, FRAME, out, MAX_PACKET);
    if (r < 1) return 5;
    write_frame(out, (uint32_t)r);
  }
}
