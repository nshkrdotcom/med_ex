// Test-only scripted POSIX I/O and codec boundary. This does not qualify libopus.
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static uint8_t input[4096], output[4096];
static size_t input_size, input_offset, output_size;
static unsigned reads, writes, creates, destroys, encodes;
static int read_error, write_error, zero_write, codec_error, create_error, long_hello;

ssize_t scripted_read(int fd, void *buffer, size_t length) {
  assert(fd == STDIN_FILENO);
  if (read_error) { errno = EIO; return -1; }
  if (++reads % 3 == 1) { errno = EINTR; return -1; }
  size_t count = input_size - input_offset;
  if (count > length) count = length;
  if (count > 3) count = 3;
  memcpy(buffer, input + input_offset, count);
  input_offset += count;
  return (ssize_t)count;
}

ssize_t scripted_write(int fd, const void *buffer, size_t length) {
  assert(fd == STDOUT_FILENO);
  if (write_error && output_size >= (size_t)(write_error - 1)) {
    errno = EPIPE;
    return -1;
  }
  if (zero_write) return 0;
  if (++writes % 3 == 1) { errno = EINTR; return -1; }
  size_t count = length > 2 ? 2 : length;
  assert(output_size + count <= sizeof output);
  memcpy(output + output_size, buffer, count);
  output_size += count;
  return (ssize_t)count;
}

#define read scripted_read
#define write scripted_write
#define main encoder_supervisor_main
#include "../c_src/opus_encoder.c"
#undef main
#undef write
#undef read

static OpusEncoder codec;

OpusEncoder *opus_encoder_create(opus_int32 rate, int channels, int application, int *error) {
  assert(rate == 48000 && channels == 1 && application == OPUS_APPLICATION_AUDIO);
  creates++;
  *error = create_error ? -1 : OPUS_OK;
  return create_error ? NULL : &codec;
}

void opus_encoder_destroy(OpusEncoder *encoder) {
  assert(encoder == &codec);
  destroys++;
}

const char *opus_get_version_string(void) {
  return long_hello ? "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" : "libopus test";
}

opus_int32 opus_encode(OpusEncoder *encoder, const opus_int16 *pcm, int count,
                      unsigned char *packet, opus_int32 capacity) {
  static const int32_t expected[] = {-32768, -1, 0, 32767};
  assert(encoder == &codec && count == 960 && capacity == 1275);
  for (int i = 0; i < count; i++) assert(pcm[i] == expected[i % 4]);
  encodes++;
  if (codec_error) return -1;
  packet[0] = 'P';
  return 1;
}

static void frame(void) {
  static const uint8_t extremes[] = {0x00, 0x80, 0xff, 0xff, 0, 0, 0xff, 0x7f};
  const uint8_t header[] = {0, 0, 7, 128};
  memcpy(input + input_size, header, sizeof header);
  input_size += sizeof header;
  for (int i = 0; i < 240; i++) {
    memcpy(input + input_size, extremes, sizeof extremes);
    input_size += sizeof extremes;
  }
}

static void check_output(unsigned packets) {
  static const char hello[] = "med_ex_opus/1 libopus test";
  size_t size = sizeof hello - 1;
  assert(output_size == 4 + size + packets * 5);
  assert(output[0] == 0 && output[1] == 0 && output[2] == 0 && output[3] == size);
  assert(memcmp(output + 4, hello, size) == 0);
  for (unsigned i = 0; i < packets; i++) {
    const uint8_t packet[] = {0, 0, 0, 1, 'P'};
    assert(memcmp(output + 4 + size + i * 5, packet, sizeof packet) == 0);
  }
}

int main(int argc, char **argv) {
  assert(argc == 2);
  const char *test = argv[1];
  int expected = 0;
  unsigned expected_packets = 0;
  int check_frames = 1;

  if (strcmp(test, "clean_eof") == 0) {
    // Empty input still initializes, sends hello and destroys the codec.
  } else if (strcmp(test, "fragmented_frames") == 0) {
    frame(); frame(); expected_packets = 2;
  } else if (strcmp(test, "short_header") == 0) {
    input_size = 3; expected = 4;
  } else if (strcmp(test, "short_payload") == 0) {
    frame(); input_size--; expected = 4;
  } else if (strcmp(test, "invalid_length") == 0) {
    memset(input, 0xff, 4); input_size = 4; expected = 4;
  } else if (strcmp(test, "read_error") == 0) {
    read_error = 1; expected = 4;
  } else if (strcmp(test, "write_error_header") == 0) {
    write_error = 1; expected = 2; check_frames = 0;
  } else if (strcmp(test, "write_error_payload") == 0) {
    write_error = 5; expected = 2; check_frames = 0;
  } else if (strcmp(test, "zero_write") == 0) {
    zero_write = 1; expected = 2; check_frames = 0;
  } else if (strcmp(test, "codec_error") == 0) {
    frame(); codec_error = 1; expected = 5;
  } else if (strcmp(test, "hello_overflow") == 0) {
    long_hello = 1; expected = 3; check_frames = 0;
  } else if (strcmp(test, "create_error") == 0) {
    create_error = 1; expected = 3; check_frames = 0;
  } else if (strcmp(test, "exact_read_states") == 0) {
    uint8_t buffer[4];
    assert(read_exact(buffer, sizeof buffer) == 0);
    input_size = 3;
    assert(read_exact(buffer, sizeof buffer) == -1);
    read_error = 1;
    assert(read_exact(buffer, sizeof buffer) == -2);
    return 0;
  } else {
    assert(!"unknown test");
  }

  assert(encode() == expected);
  assert(creates == 1);
  assert(destroys == (create_error ? 0u : 1u));
  if (check_frames) check_output(expected_packets);
  assert(encodes == expected_packets + (codec_error ? 1u : 0u));
  if (expected == 0) assert(reads > 0 && writes > 0);
  return 0;
}
