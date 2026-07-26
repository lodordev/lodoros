// lodor-fbhelper.c (SDL 1.2 / MI_GFX) — the LodorOS launch-card frame-helper for the
// armhf SigmaStar panels (miyoomini: Miyoo Mini Plus / Mini Flip, SSD202D) where raw
// /dev/fb0 is a DEAD scanout surface. It is the armhf/SDL1.2 sibling of
// integrations/nextui/fbhelper/lodor-fbhelper.c (SDL2, aarch64) — SAME wire protocol,
// SAME role: a PURE PIXEL PUSHER. Go composes every pixel of the interactive card into an
// RGB565 Canvas and pipes raw frames here; this binary only pushes them to the panel via
// the custom MinUI SDL 1.2 (SDL_SetVideoMode + SDL_Flip), which scans out through MI_GFX
// on the SSD202D exactly as minui.elf / minarch do (workspace/miyoomini/platform: PLAT_flip
// direct path == SDL_Flip). It carries NO Lodor/RomM logic.
//
// INPUT (miyoomini reality, corrected 2026-07-24): MinUI's custom SDL opens AND exclusively
// GRABS the keypad (/dev/input/event0) as part of video init — so the wizard's separate Go
// EvdevSource is starved (rc7: card rendered, ZERO presses, watchdog fired at 30s). SDL owns
// the keypad; fighting the grab is fragile. So on this lane the helper FORWARDS the key events
// SDL already delivers, up fd 3 as "#btn code=<scancode>" lines, and the wizard maps the
// scancode via its keymap. This is the SAME input path minui/minarch use (SDL_KEYDOWN
// scancodes, api.c). (The SDL2/NextUI helper stays display-only — SDL2 there doesn't grab
// evdev, so that lane keeps the wizard's own EvdevSource.)
//
// PROTOCOL (identical to the SDL2 helper — shared with engine/ui/sdlhelper.go):
//   fd 0 (stdin): a 16-byte header ONCE, then raw frames forever.
//     header: 'L' 'F' 'B' '1'  (magic)
//             u32 LE  width
//             u32 LE  height
//             u32 LE  bytesperpixel  (2 = RGB565 — what the Go side always sends; 4 = RGBA8888)
//     frame : width*height*bytesperpixel raw bytes. Read fully; flip on each complete frame.
//             Short read / EOF on stdin => clean exit.
//   fd 3 (diag pipe, write): a "#surface ...\n" line at startup, then "#btn code=<scancode>\n"
//             for each SDL_KEYDOWN (forwarded input — see INPUT note above). Falls back to
//             stdout if fd 3 is closed.
//   SIGTERM / SDL_QUIT / stdin EOF => exit(0) WITHOUT blanking the panel (caller owns teardown).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <SDL/SDL.h>

#define MAGIC0 'L'
#define MAGIC1 'F'
#define MAGIC2 'B'
#define MAGIC3 '1'

static volatile sig_atomic_t g_quit = 0;
static void on_term(int sig) { (void)sig; g_quit = 1; }

static int g_diagfd = 3; // diag pipe; falls back to stdout(1) if fd 3 is closed

// read exactly n bytes from fd into buf; returns 1 on success, 0 on clean EOF, -1 on error.
static int read_full(int fd, void *buf, size_t n) {
	uint8_t *p = (uint8_t *)buf;
	size_t got = 0;
	while (got < n) {
		ssize_t r = read(fd, p + got, n - got);
		if (r == 0) return 0;                    // EOF
		if (r < 0) { if (errno == EINTR) continue; return -1; }
		got += (size_t)r;
	}
	return 1;
}

static void emit(const char *s) {
	ssize_t r = write(g_diagfd, s, strlen(s));
	if (r < 0 && g_diagfd != 1) { g_diagfd = 1; (void)write(g_diagfd, s, strlen(s)); }
}
static void emitf(const char *fmt, ...) {
	char b[160]; va_list ap; va_start(ap, fmt);
	vsnprintf(b, sizeof(b), fmt, ap); va_end(ap); emit(b);
}

int main(void) {
	signal(SIGTERM, on_term);
	signal(SIGINT, on_term);
	signal(SIGPIPE, SIG_IGN);

	// If fd 3 isn't open (standalone), fall back to stdout for the diag line.
	if (fcntl(3, F_GETFD) == -1) g_diagfd = 1;

	// --- read header ---
	uint8_t hdr[16];
	int hr = read_full(0, hdr, sizeof(hdr));
	if (hr != 1) { fprintf(stderr, "fbhelper: no header\n"); return 4; }
	if (hdr[0]!=MAGIC0||hdr[1]!=MAGIC1||hdr[2]!=MAGIC2||hdr[3]!=MAGIC3) {
		fprintf(stderr, "fbhelper: bad magic\n"); return 4;
	}
	uint32_t W  = (uint32_t)hdr[4]  | (hdr[5]<<8)  | (hdr[6]<<16)  | ((uint32_t)hdr[7]<<24);
	uint32_t H  = (uint32_t)hdr[8]  | (hdr[9]<<8)  | (hdr[10]<<16) | ((uint32_t)hdr[11]<<24);
	uint32_t BP = (uint32_t)hdr[12] | (hdr[13]<<8) | (hdr[14]<<16) | ((uint32_t)hdr[15]<<24);
	if (W==0||H==0||(BP!=2&&BP!=4)||W>4096||H>4096) {
		fprintf(stderr, "fbhelper: bad geom %ux%u bp=%u\n", W, H, BP); return 4;
	}
	size_t frame_bytes = (size_t)W * H * BP;
	uint8_t *frame = (uint8_t *)malloc(frame_bytes);
	if (!frame) { fprintf(stderr, "fbhelper: oom %zu\n", frame_bytes); return 4; }

	// --- SDL 1.2 bring-up: the proven MinUI present path, VIDEO ONLY ---
	// The custom MinUI SDL owns the MI_SYS/MI_GFX bring-up internally; we mirror platform.c's
	// PLAT_initVideo/PLAT_flip direct path. DELIBERATELY no SDL_INIT_JOYSTICK and no input node
	// opens — input is owned by the wizard's Go EvdevSource; an SDL grab here would starve it.
	if (SDL_Init(SDL_INIT_VIDEO) < 0) {
		fprintf(stderr, "fbhelper: SDL_Init(VIDEO): %s\n", SDL_GetError()); free(frame); return 4;
	}
	SDL_ShowCursor(0);
	// Native panel depth is 16bpp RGB565 (workspace/miyoomini/platform.h); request it so a
	// BP=2 frame blits 1:1 and a BP=4 frame down-converts on blit. SWSURFACE matches minui.
	SDL_Surface *screen = SDL_SetVideoMode((int)W, (int)H, 16, SDL_SWSURFACE);
	if (!screen || !screen->format || screen->w <= 0 || screen->h <= 0) {
		fprintf(stderr, "fbhelper: SDL_SetVideoMode: %s\n", SDL_GetError()); SDL_Quit(); free(frame); return 4;
	}
	emitf("#surface w=%d h=%d bpp=%d wantw=%u wanth=%u bp=%u input=sdl-forward sdl=1.2\n",
	      screen->w, screen->h, screen->format->BitsPerPixel, W, H, BP);

	// One source surface wrapping the incoming frame, with explicit masks (SDL1.2 has no
	// SDL_CreateRGBSurfaceWithFormatFrom). RGB565: R high 5 bits. RGBA8888 for the BP=4 case.
	SDL_Surface *src;
	if (BP == 2) {
		src = SDL_CreateRGBSurfaceFrom(frame, (int)W, (int)H, 16, (int)(W*2),
		                               0xF800, 0x07E0, 0x001F, 0x0000);
	} else {
		src = SDL_CreateRGBSurfaceFrom(frame, (int)W, (int)H, 32, (int)(W*4),
		                               0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000);
	}
	if (!src) { fprintf(stderr, "fbhelper: src surface: %s\n", SDL_GetError()); SDL_Quit(); free(frame); return 4; }
	SDL_Rect dst = { (Sint16)((screen->w - (int)W)/2), (Sint16)((screen->h - (int)H)/2), (Uint16)W, (Uint16)H };
	if ((int)dst.x < 0) dst.x = 0;
	if ((int)dst.y < 0) dst.y = 0;

	// INPUT (miyoomini): on MinUI's custom SDL the keypad is /dev/input/event0, opened and GRABBED
	// exclusively by SDL's video init — so a SEPARATE evdev reader (the Go wizard) is starved and
	// gets ZERO events (proven on-device rc7: the card rendered but the idle watchdog fired at 30s).
	// So the helper is NOT display-only on this lane: it FORWARDS the key presses SDL already
	// delivers, up fd 3 as "#btn code=<scancode>" lines; the wizard maps the scancode via its
	// keymap. That requires polling SDL's queue CONTINUOUSLY — the card is event-driven and sends
	// no frames while waiting for input, so we can't poll only after a frame. stdin goes
	// non-blocking and we interleave event-poll + frame-read on this ONE thread (SDL 1.2 event
	// calls must stay on the video thread), flipping only when a whole frame has arrived.
	{ int fl = fcntl(0, F_GETFL, 0); if (fl != -1) fcntl(0, F_SETFL, fl | O_NONBLOCK); }
	int rc = 0;
	size_t got = 0;   // bytes of the in-progress frame accumulated so far
	while (!g_quit) {
		// 1) forward input first, every iteration (low latency, independent of frame arrival)
		SDL_PumpEvents();
		SDL_Event ev;
		while (SDL_PollEvent(&ev)) {
			if (ev.type == SDL_QUIT) { g_quit = 1; break; }
			else if (ev.type == SDL_KEYDOWN) emitf("#btn code=%d\n", (int)ev.key.keysym.scancode);
			// JOY events are LOGGED (not forwarded) so an unexpected input path is visible on-device
			else if (ev.type == SDL_JOYBUTTONDOWN) emitf("#btnjoy button=%d\n", (int)ev.jbutton.button);
			else if (ev.type == SDL_JOYHATMOTION)  emitf("#btnhat value=%d\n", (int)ev.jhat.value);
		}
		if (g_quit) break;

		// 2) read whatever frame bytes are available (non-blocking); flip on a COMPLETE frame.
		ssize_t r = read(0, frame + got, frame_bytes - got);
		if (r == 0) break;                          // EOF => host closed the pipe, exit 0
		if (r > 0) {
			got += (size_t)r;
			if (got == frame_bytes) {               // full frame — scan out via MI_GFX
				got = 0;
				SDL_FillRect(screen, NULL, 0);      // black letterbox bars
				SDL_BlitSurface(src, NULL, screen, &dst);
				SDL_Flip(screen);
			}
			continue;                               // more bytes may be ready — don't sleep
		}
		if (errno == EINTR) continue;
		if (errno == EAGAIN || errno == EWOULDBLOCK) { SDL_Delay(4); continue; } // idle — yield ~4ms
		rc = 4; break;                              // real read error
	}

	SDL_FreeSurface(src);
	SDL_Quit();          // NOTE: does NOT blank the panel; caller owns teardown.
	free(frame);
	return rc;
}
