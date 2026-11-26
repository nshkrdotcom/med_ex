// Decode one real encoder packet using the same pinned archive as the build.
#include <opus.h>
#include <stdint.h>
#include <stdio.h>

int main(int argc, char **argv) {
  if (argc != 2) return 1;
  FILE *packet = fopen(argv[1], "rb");
  if (!packet) return 1;
  unsigned char data[1276];
  size_t len = fread(data, 1, sizeof data, packet);
  fclose(packet);
  if (!len || len == sizeof data) return 1;

  int err;
  OpusDecoder *decoder = opus_decoder_create(48000, 1, &err);
  if (err != OPUS_OK) return 1;
  opus_int16 samples[960];
  int count = opus_decode(decoder, data, (opus_int32)len, samples, 960, 0);
  opus_decoder_destroy(decoder);
  if (count != 960) return 1;
  int64_t energy = 0;
  for (int i = 0; i < count; i++) energy += (int64_t)samples[i] * samples[i];
  return energy > (int64_t)count * 1000000 ? 0 : 1;
}
