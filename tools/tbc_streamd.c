// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * TBC Test Suite - SD video streaming daemon (runs on the MiSTer ARM).
 *
 * Streams a pre-converted .sbin (360x480 RGB565, 4608-byte header) from
 * the SD card into the core's DDR ring buffer. The reserved core-DDR
 * region is outside the kernel's linear map, so access must go through
 * mmap(/dev/mem) - read()/write() syscalls fail there with EFAULT.
 *
 * Control block at 0x3F7F0000 (64-bit LE words):
 *   [0] magic 0x5442435300000001   [1] width  [2] total frames
 *   [3] ring frames (power of 2)   [4] writer frame (daemon, monotonic)
 *   [5] reader frame (written by the core each field)
 *   [6] session id (daemon; the core ignores it)
 * Ring data at 0x30000000, tight frame packing. The daemon primes half
 * the ring, publishes the header (magic last), then paces itself
 * against the core's reader index. The file loops forever; SIGTERM
 * clears the magic and exits.
 *
 * Ownership: the session writes its id to [6] and a PRIMING marker to
 * [0], and checks before every frame it copies that both are still its
 * own (PRIMING until published, MAGIC after). Anything else means the
 * DDR region was taken over - a clip load through the OSD (the core's
 * loader zeroes [0]) or a newer daemon (new id) - and the session exits
 * at once without touching the control block, instead of writing over
 * the new owner's data (it used to re-publish the stream over a clip
 * being loaded).
 *
 * The streaming loop is stream_tick() so sim/stream can drive this exact
 * code against the simulated core (build with -DTBC_STREAMD_NO_MAIN).
 *
 * Build (static, from repo root):
 *   docker run --rm -v "$PWD/tools":/w -w /w debian:bookworm sh -c \
 *     "apt-get update -qq && apt-get install -y -qq gcc-arm-linux-gnueabihf && \
 *      arm-linux-gnueabihf-gcc -static -O2 -o tbc_streamd tbc_streamd.c"
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>

#define CTRL_PHYS   0x3F7F0000UL
#define RING_PHYS   0x30000000UL
#define MAGIC       0x5442435300000001ULL
#define PRIMING     0x5442435300000000ULL   /* not MAGIC: the core ignores it */
#define HDR_BYTES   4608
#define FRAME_BYTES 345600UL      /* 360*480*2 */
#define RING_FRAMES 256UL
#define CHUNK       16            /* frames per write burst */

struct stream {
	FILE              *f;
	volatile uint64_t *ctrl;
	uint8_t           *ring;
	uint8_t           *buf;       /* CHUNK frames */
	uint64_t           total;     /* frames in the file */
	uint64_t           writer;    /* frames written (monotonic) */
	uint64_t           fidx;      /* next frame to read from the file */
	uint64_t           id;        /* session id in ctrl[6] */
	int                live;      /* published (MAGIC) */
};

enum { TICK_WROTE = 0, TICK_WAIT = 1, TICK_STOP = 2 };

/* open the file and set up the session; ctrl/ring already mapped */
static int stream_open(struct stream *s, const char *path)
{
	memset(s, 0, sizeof(*s));
	s->f = fopen(path, "rb");
	if (!s->f) { perror("open sbin"); return -1; }
	uint64_t hdr[4];
	if (fread(hdr, 8, 4, s->f) != 4 || hdr[0] != MAGIC || hdr[1] != 360) {
		fprintf(stderr, "not a valid .sbin (magic/width)\n"); return -1;
	}
	fseeko(s->f, 0, SEEK_END);
	s->total = (uint64_t)(ftello(s->f) - HDR_BYTES) / FRAME_BYTES;
	if (s->total < 1) { fprintf(stderr, "file too short\n"); return -1; }
	s->buf = (uint8_t *)malloc(CHUNK * FRAME_BYTES);
	if (!s->buf) { perror("malloc"); return -1; }
	fseeko(s->f, HDR_BYTES, SEEK_SET);
	return 0;
}

static void stream_start(struct stream *s)
{
	static uint64_t n;
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	s->id = ((uint64_t)getpid() << 40) ^ ((uint64_t)ts.tv_sec << 20) ^ (uint64_t)ts.tv_nsec ^ ++n;
	s->live = 0;
	s->ctrl[0] = PRIMING;   /* invalidate while (re)priming */
	s->ctrl[6] = s->id;
	__sync_synchronize();
}

/* still the owner of the control block / ring? */
static int stream_owned(const struct stream *s)
{
	return s->ctrl[6] == s->id && s->ctrl[0] == (s->live ? MAGIC : PRIMING);
}

/* one pass of the streaming loop: TICK_WAIT means "sleep ~100 ms" */
static int stream_tick(struct stream *s)
{
	volatile uint64_t *ctrl = s->ctrl;

	if (!stream_owned(s)) {
		printf("DDR region taken over (clip load or another stream) - stopping\n");
		return TICK_STOP;
	}

	/* pace against the core once the stream is live. Signed: a reader
	 * ahead of the writer (the core resyncing to a new session) means
	 * "keep writing", not a huge unsigned lag that waits forever. */
	if (s->live) {
		int64_t lag = (int64_t)(s->writer - ctrl[5]);
		if (lag > (int64_t)(RING_FRAMES - CHUNK - 8)) return TICK_WAIT;
	}

	uint64_t slot = s->writer & (RING_FRAMES - 1);
	uint64_t n = CHUNK;
	if (slot + n > RING_FRAMES) n = RING_FRAMES - slot;
	if (s->fidx + n > s->total) n = s->total - s->fidx;

	if (fread(s->buf, FRAME_BYTES, n, s->f) != n) { fprintf(stderr, "read error\n"); return TICK_STOP; }
	/* frame by frame, re-checking ownership: a clip load that starts
	 * mid-chunk can overlap at most the one frame in flight */
	for (uint64_t i = 0; i < n; i++) {
		if (!stream_owned(s)) {
			printf("DDR region taken over (clip load or another stream) - stopping\n");
			return TICK_STOP;
		}
		memcpy(s->ring + (slot + i) * FRAME_BYTES, s->buf + i * FRAME_BYTES, FRAME_BYTES);
	}
	s->writer += n;
	s->fidx   += n;
	ctrl[4] = s->writer;
	if (s->fidx >= s->total) { s->fidx = 0; fseeko(s->f, HDR_BYTES, SEEK_SET); }

	/* publish the stream once half the ring is primed */
	if (!s->live && s->writer >= RING_FRAMES / 2) {
		ctrl[1] = 360;
		ctrl[2] = s->total;
		ctrl[3] = RING_FRAMES;
		ctrl[5] = 0;
		__sync_synchronize();
		ctrl[0] = MAGIC;
		s->live = 1;
		printf("stream live\n");
	}
	return TICK_WROTE;
}

/* release the block - only if it is still ours */
static void stream_stop(struct stream *s)
{
	if (stream_owned(s)) s->ctrl[0] = 0;
}

#ifndef TBC_STREAMD_NO_MAIN
static volatile sig_atomic_t stop_req = 0;
static void on_sig(int sig) { (void)sig; stop_req = 1; }

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: %s <file.sbin>\n", argv[0]); return 1; }

	struct stream s;
	if (stream_open(&s, argv[1]) < 0) return 1;

	int mem = open("/dev/mem", O_RDWR | O_SYNC);
	if (mem < 0) { perror("open /dev/mem"); return 1; }
	s.ctrl = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, mem, CTRL_PHYS);
	s.ring = mmap(NULL, RING_FRAMES * FRAME_BYTES,
	              PROT_READ | PROT_WRITE, MAP_SHARED, mem, RING_PHYS);
	if (s.ctrl == MAP_FAILED || s.ring == MAP_FAILED) { perror("mmap"); return 1; }

	signal(SIGTERM, on_sig);
	signal(SIGINT, on_sig);

	stream_start(&s);
	printf("streaming %s: %llu frames (%llu s), looping\n",
	       argv[1], (unsigned long long)s.total, (unsigned long long)(s.total / 30));

	while (!stop_req) {
		int r = stream_tick(&s);
		if (r == TICK_STOP) break;
		if (r == TICK_WAIT) usleep(100000);
	}

	stream_stop(&s);
	printf("stream stopped\n");
	return 0;
}
#endif
