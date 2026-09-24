#define _GNU_SOURCE
#include <alsa/asoundlib.h>
#include <alsa/pcm_external.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/timerfd.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define RATE 48000U
#define PACKET 480U
#define RING 8192U

typedef struct {
  snd_pcm_ioplug_t io;
  int sock, timer, running, dead;
  uint64_t start_ns, base, sent, boundary, app_cycles, last_app;
  int16_t playback[RING], capture[RING];
  unsigned head, count;
  double phase;
} mux_pcm;

static uint64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}

static uint64_t position(mux_pcm *p) {
  uint64_t elapsed = p->running ? now_ns() - p->start_ns : 0;
  return p->base + elapsed / 1000000000ULL * RATE +
         elapsed % 1000000000ULL * RATE / 1000000000ULL;
}

static uint64_t application(mux_pcm *p) {
  uint64_t value = p->io.appl_ptr;
  if (value < p->last_app && p->last_app - value > p->boundary / 2)
    p->app_cycles += p->boundary;
  else if (value > p->last_app && value - p->last_app > p->boundary / 2 &&
           p->app_cycles >= p->boundary)
    p->app_cycles -= p->boundary;
  p->last_app = value;
  return p->app_cycles + value;
}

static int command(mux_pcm *p, uint8_t op) {
  if (send(p->sock, &op, 1, MSG_DONTWAIT | MSG_NOSIGNAL) != 1) {
    p->dead = 1;
    return -ENODEV;
  }
  return 0;
}

static int start(snd_pcm_ioplug_t *io) {
  mux_pcm *p = io->private_data;
  int err = command(p, 1);
  if (err < 0)
    return err;
  p->start_ns = now_ns();
  p->running = 1;
  return 0;
}

static int stop(snd_pcm_ioplug_t *io) {
  mux_pcm *p = io->private_data;
  p->base = position(p);
  p->running = 0;
  return command(p, 0);
}

static void receive_capture(mux_pcm *p) {
  uint8_t packet[PACKET * 2];
  for (unsigned packets = 0; packets < 32; packets++) {
    ssize_t size =
        recv(p->sock, packet, sizeof(packet), MSG_DONTWAIT | MSG_TRUNC);
    if (size < 0 && (errno == EAGAIN || errno == EINTR))
      return;
    if (size <= 0 || size > (ssize_t)sizeof(packet) || size % 2) {
      p->dead = 1;
      return;
    }
    for (ssize_t i = 0; i < size; i += 2) {
      if (p->count == RING) {
        p->head = (p->head + 1) % RING;
        p->count--;
      }
      p->capture[(p->head + p->count++) % RING] =
          (int16_t)((uint16_t)packet[i] | (uint16_t)packet[i + 1] << 8);
    }
  }
}

static int prepare(snd_pcm_ioplug_t *io) {
  mux_pcm *p = io->private_data;
  if (p->dead || command(p, 0) < 0)
    return -ENODEV;
  p->running = 0;
  p->base = p->sent = p->app_cycles = p->last_app = 0;
  if (io->stream == SND_PCM_STREAM_CAPTURE)
    receive_capture(p);
  p->head = p->count = 0;
  p->phase = 0;
  memset(p->playback, 0, sizeof(p->playback));
  /* CPAL primes PREPARED playback before ALSA auto-starts it. */
  struct itimerspec timer = {.it_interval = {0, 10000000},
                             .it_value = {0, 10000000}};
  return timerfd_settime(p->timer, 0, &timer, NULL) < 0 ? -errno : 0;
}

static snd_pcm_sframes_t pointer(snd_pcm_ioplug_t *io) {
  mux_pcm *p = io->private_data;
  uint64_t pos = position(p), app = application(p);
  if (io->stream == SND_PCM_STREAM_PLAYBACK &&
      io->state == SND_PCM_STATE_DRAINING && pos > app)
    pos = app;
  if (p->running &&
      ((io->stream == SND_PCM_STREAM_PLAYBACK && pos > app) ||
       (io->stream == SND_PCM_STREAM_CAPTURE && pos > app + io->buffer_size)))
    return -EPIPE;
  if (p->running && io->stream == SND_PCM_STREAM_PLAYBACK) {
    while (p->sent < pos) {
      uint8_t packet[1 + PACKET * 2] = {2};
      unsigned count =
          pos - p->sent > PACKET ? PACKET : (unsigned)(pos - p->sent);
      for (unsigned i = 0; i < count; i++) {
        uint16_t sample = (uint16_t)p->playback[(p->sent + i) % RING];
        packet[1 + 2 * i] = sample & 255;
        packet[2 + 2 * i] = sample >> 8;
      }
      ssize_t result =
          send(p->sock, packet, 1 + count * 2, MSG_DONTWAIT | MSG_NOSIGNAL);
      if (result < 0 && errno != EAGAIN && errno != EINTR)
        p->dead = 1;
      p->sent += count;
    }
  }
  return (snd_pcm_sframes_t)(pos % p->boundary);
}

static snd_pcm_sframes_t transfer(snd_pcm_ioplug_t *io,
                                  const snd_pcm_channel_area_t *areas,
                                  snd_pcm_uframes_t offset,
                                  snd_pcm_uframes_t frames) {
  mux_pcm *p = io->private_data;
  if (p->dead)
    return -ENODEV;
  if (areas[0].step != 16 || areas[0].first % 8)
    return -EINVAL;
  uint8_t *data =
      (uint8_t *)areas[0].addr + (areas[0].first + offset * areas[0].step) / 8;
  uint64_t app = application(p);
  if (io->stream == SND_PCM_STREAM_CAPTURE)
    receive_capture(p);
  /* A small bounded correction follows the sender's independent clock. */
  double step = p->count > io->period_size + PACKET ? 1.001
                : p->count < io->period_size        ? 0.999
                                                    : 1.0;
  for (snd_pcm_uframes_t i = 0; i < frames; i++) {
    if (io->stream == SND_PCM_STREAM_PLAYBACK) {
      p->playback[(app + i) % RING] =
          (int16_t)((uint16_t)data[2 * i] | (uint16_t)data[2 * i + 1] << 8);
    } else {
      int16_t sample = 0;
      if (p->count >= 2) {
        double a = p->capture[p->head], b = p->capture[(p->head + 1) % RING];
        sample = (int16_t)(a + (b - a) * p->phase);
        p->phase += step;
        unsigned consumed = (unsigned)p->phase;
        p->phase -= consumed;
        p->head = (p->head + consumed) % RING;
        p->count -= consumed;
      } else
        p->phase = 0;
      data[2 * i] = (uint16_t)sample & 255;
      data[2 * i + 1] = (uint16_t)sample >> 8;
    }
  }
  return p->dead ? -ENODEV : (snd_pcm_sframes_t)frames;
}

static int sw_params(snd_pcm_ioplug_t *io, snd_pcm_sw_params_t *params) {
  mux_pcm *p = io->private_data;
  snd_pcm_uframes_t boundary;
  int result = snd_pcm_sw_params_get_boundary(params, &boundary);
  if (result >= 0 && boundary)
    p->boundary = boundary;
  return result;
}

static int descriptors_count(snd_pcm_ioplug_t *io) {
  (void)io;
  return 2;
}
static int descriptors(snd_pcm_ioplug_t *io, struct pollfd *fds,
                       unsigned space) {
  mux_pcm *p = io->private_data;
  if (space < 2)
    return -EINVAL;
  fds[0] = (struct pollfd){p->timer, POLLIN, 0};
  fds[1] = (struct pollfd){
      p->sock, io->stream == SND_PCM_STREAM_CAPTURE ? POLLIN : 0, 0};
  return 2;
}
static int revents(snd_pcm_ioplug_t *io, struct pollfd *fds, unsigned count,
                   unsigned short *out) {
  mux_pcm *p = io->private_data;
  if (count != 2)
    return -EINVAL;
  *out = (fds[0].revents | fds[1].revents) & (POLLERR | POLLHUP | POLLNVAL);
  if (*out)
    p->dead = 1;
  if (fds[1].revents & POLLIN)
    receive_capture(p);
  if (p->dead) {
    *out |= POLLERR | POLLHUP;
    return 0;
  }
  if (fds[0].revents & POLLIN) {
    uint64_t ticks;
    ssize_t ignored = read(p->timer, &ticks, sizeof(ticks));
    (void)ignored;
    *out |= io->stream == SND_PCM_STREAM_PLAYBACK ? POLLOUT : POLLIN;
  }
  return 0;
}

static int close_pcm(snd_pcm_ioplug_t *io) {
  mux_pcm *p = io->private_data;
  close(p->timer);
  close(p->sock);
  free(p);
  return 0;
}
static const snd_pcm_ioplug_callback_t callbacks = {
    .start = start,
    .stop = stop,
    .prepare = prepare,
    .pointer = pointer,
    .transfer = transfer,
    .sw_params = sw_params,
    .poll_descriptors_count = descriptors_count,
    .poll_descriptors = descriptors,
    .poll_revents = revents,
    .close = close_pcm,
};

SND_PCM_PLUGIN_DEFINE_FUNC(mux) {
  (void)root;
  char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
  snprintf(path, sizeof(path), "/tmp/muxd-%u.sock.audio", (unsigned)getuid());
  snd_config_iterator_t iter, next;
  snd_config_for_each(iter, next, conf) {
    snd_config_t *entry = snd_config_iterator_entry(iter);
    const char *id, *value;
    if (snd_config_get_id(entry, &id) < 0)
      continue;
    if (!strcmp(id, "type") || !strcmp(id, "comment") || !strcmp(id, "hint"))
      continue;
    if (strcmp(id, "socket") || snd_config_get_string(entry, &value) < 0 ||
        strlen(value) >= sizeof(path))
      return -EINVAL;
    strcpy(path, value);
  }
  mux_pcm *p = calloc(1, sizeof(*p));
  if (!p)
    return -ENOMEM;
  p->timer = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
  p->sock = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  memcpy(address.sun_path, path, strlen(path) + 1);
  if (p->timer < 0 || p->sock < 0)
    goto failed;
  struct timeval timeout = {.tv_sec = 2};
  int queue_bytes = PACKET * 2 * 8;
  if (setsockopt(p->sock, SOL_SOCKET, SO_RCVBUF, &queue_bytes,
                 sizeof(queue_bytes)) < 0)
    goto failed;
  if (setsockopt(p->sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) <
          0 ||
      setsockopt(p->sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) <
          0 ||
      connect(p->sock, (void *)&address, sizeof(address)) < 0)
    goto failed;
  uint8_t hello[2] = {1, stream == SND_PCM_STREAM_CAPTURE}, reply;
  if (send(p->sock, hello, sizeof(hello), MSG_NOSIGNAL) != sizeof(hello) ||
      recv(p->sock, &reply, 1, 0) != 1 || reply != 0) {
    errno = ENODEV;
    goto failed;
  }
  if (fcntl(p->sock, F_SETFL, O_NONBLOCK) < 0)
    goto failed;
  p->boundary = 1ULL << 62;
  p->io.version = SND_PCM_IOPLUG_VERSION;
  p->io.name = "Mux remote audio";
  p->io.flags = SND_PCM_IOPLUG_FLAG_MONOTONIC | SND_PCM_IOPLUG_FLAG_BOUNDARY_WA;
  p->io.callback = &callbacks;
  p->io.private_data = p;
  int result = snd_pcm_ioplug_create(&p->io, name, stream, mode);
  if (result < 0) {
    close_pcm(&p->io);
    return result;
  }
  const unsigned access[] = {SND_PCM_ACCESS_RW_INTERLEAVED},
                 format[] = {SND_PCM_FORMAT_S16_LE};
  if ((result = snd_pcm_ioplug_set_param_list(&p->io, SND_PCM_IOPLUG_HW_ACCESS,
                                              1, access)) < 0 ||
      (result = snd_pcm_ioplug_set_param_list(&p->io, SND_PCM_IOPLUG_HW_FORMAT,
                                              1, format)) < 0 ||
      (result = snd_pcm_ioplug_set_param_minmax(
           &p->io, SND_PCM_IOPLUG_HW_CHANNELS, 1, 1)) < 0 ||
      (result = snd_pcm_ioplug_set_param_minmax(&p->io, SND_PCM_IOPLUG_HW_RATE,
                                                RATE, RATE)) < 0 ||
      (result = snd_pcm_ioplug_set_param_minmax(
           &p->io, SND_PCM_IOPLUG_HW_PERIOD_BYTES, 960, 8192)) < 0 ||
      (result = snd_pcm_ioplug_set_param_minmax(
           &p->io, SND_PCM_IOPLUG_HW_BUFFER_BYTES, 1920, RING * 2)) < 0 ||
      (result = snd_pcm_ioplug_set_param_minmax(
           &p->io, SND_PCM_IOPLUG_HW_PERIODS, 2, 2)) < 0) {
    snd_pcm_ioplug_delete(&p->io);
    return result;
  }
  *pcmp = p->io.pcm;
  return 0;
failed: {
  int error = errno;
  if (p->timer >= 0)
    close(p->timer);
  if (p->sock >= 0)
    close(p->sock);
  free(p);
  return -error;
}
}
SND_PCM_PLUGIN_SYMBOL(mux);
