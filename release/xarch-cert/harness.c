/* xarch-cert harness: minimal libretro runner for cross-architecture
 * save-state certification (Lodor Handoff D8).
 *
 * Modes:
 *   ./harness <core.so> <rom> gen  <frames> <out.state>   run N frames, serialize
 *   ./harness <core.so> <rom> load <in.state> <out.state> unserialize, re-serialize
 * Exit 0 = success; non-zero = the core refused (that IS the verdict, not an error).
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

enum { SET_PIXEL_FORMAT = 10, GET_SYSTEM_DIRECTORY = 9, GET_SAVE_DIRECTORY = 31,
       GET_CAN_DUPE = 3, GET_LOG_INTERFACE = 27, GET_VARIABLE = 15, SET_VARIABLES = 16,
       GET_VARIABLE_UPDATE = 17 };
struct retro_game_info { const char *path; const void *data; size_t size; const char *meta; };
struct retro_system_av_info { char pad[512]; };

static const char *tmpdir = "/tmp";
static bool env_cb(unsigned cmd, void *data) {
	switch (cmd) {
	case SET_PIXEL_FORMAT: return true;
	case GET_CAN_DUPE: *(bool *)data = true; return true;
	case GET_SYSTEM_DIRECTORY: case GET_SAVE_DIRECTORY:
		*(const char **)data = tmpdir; return true;
	case GET_VARIABLE_UPDATE: *(bool *)data = false; return true;
	default: return false;
	}
}
static void video_cb(const void *d, unsigned w, unsigned h, size_t p) { (void)d;(void)w;(void)h;(void)p; }
static void audio_cb(int16_t l, int16_t r) { (void)l;(void)r; }
static size_t audio_batch_cb(const int16_t *d, size_t f) { (void)d; return f; }
static void input_poll_cb(void) {}
static int16_t input_state_cb(unsigned a, unsigned b, unsigned c, unsigned d) { (void)a;(void)b;(void)c;(void)d; return 0; }

#define SYM(name) name = dlsym(h, #name); if (!name) { fprintf(stderr, "missing sym %s\n", #name); return 10; }

int main(int argc, char **argv) {
	if (argc < 6) { fprintf(stderr, "usage: harness core rom gen|load a b\n"); return 2; }
	void *h = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
	if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 3; }
	void (*retro_set_environment)(bool (*)(unsigned, void *));
	void (*retro_set_video_refresh)(void (*)(const void *, unsigned, unsigned, size_t));
	void (*retro_set_audio_sample)(void (*)(int16_t, int16_t));
	void (*retro_set_audio_sample_batch)(size_t (*)(const int16_t *, size_t));
	void (*retro_set_input_poll)(void (*)(void));
	void (*retro_set_input_state)(int16_t (*)(unsigned, unsigned, unsigned, unsigned));
	void (*retro_init)(void);
	bool (*retro_load_game)(const struct retro_game_info *);
	void (*retro_run)(void);
	size_t (*retro_serialize_size)(void);
	bool (*retro_serialize)(void *, size_t);
	bool (*retro_unserialize)(const void *, size_t);
	void (*retro_deinit)(void);
	SYM(retro_set_environment) SYM(retro_set_video_refresh) SYM(retro_set_audio_sample)
	SYM(retro_set_audio_sample_batch) SYM(retro_set_input_poll) SYM(retro_set_input_state)
	SYM(retro_init) SYM(retro_load_game) SYM(retro_run) SYM(retro_serialize_size)
	SYM(retro_serialize) SYM(retro_unserialize) SYM(retro_deinit)

	retro_set_environment(env_cb);
	retro_set_video_refresh(video_cb);
	retro_set_audio_sample(audio_cb);
	retro_set_audio_sample_batch(audio_batch_cb);
	retro_set_input_poll(input_poll_cb);
	retro_set_input_state(input_state_cb);
	retro_init();

	FILE *rf = fopen(argv[2], "rb");
	if (!rf) { fprintf(stderr, "rom open failed\n"); return 4; }
	fseek(rf, 0, SEEK_END); long rsz = ftell(rf); fseek(rf, 0, SEEK_SET);
	void *rom = malloc(rsz);
	if (fread(rom, 1, rsz, rf) != (size_t)rsz) { fprintf(stderr, "rom read\n"); return 4; }
	fclose(rf);
	struct retro_game_info gi = { argv[2], rom, (size_t)rsz, NULL };
	if (!retro_load_game(&gi)) { fprintf(stderr, "retro_load_game refused\n"); return 5; }

	if (strcmp(argv[3], "gen") == 0) {
		int frames = atoi(argv[4]);
		for (int i = 0; i < frames; i++) retro_run();
		size_t ss = retro_serialize_size();
		void *st = malloc(ss);
		if (!retro_serialize(st, ss)) { fprintf(stderr, "serialize failed\n"); return 6; }
		FILE *out = fopen(argv[5], "wb"); fwrite(st, 1, ss, out); fclose(out);
		printf("GEN ok size=%zu\n", ss);
	} else {
		/* load (run 0 frames) or loadrun (load, run argv[6] frames, save) */
		FILE *in = fopen(argv[4], "rb");
		if (!in) { fprintf(stderr, "state open\n"); return 4; }
		fseek(in, 0, SEEK_END); long isz = ftell(in); fseek(in, 0, SEEK_SET);
		void *ist = malloc(isz);
		if (fread(ist, 1, isz, in) != (size_t)isz) { fprintf(stderr, "state read\n"); return 4; }
		fclose(in);
		size_t ss = retro_serialize_size();
		printf("LOCAL serialize_size=%zu incoming=%ld\n", ss, isz);
		if (!retro_unserialize(ist, (size_t)isz)) { printf("UNSERIALIZE refused\n"); return 7; }
		if (strcmp(argv[3], "loadrun") == 0 && argc >= 7) {
			int rf2 = atoi(argv[6]);
			for (int i = 0; i < rf2; i++) retro_run();
		}
		size_t os = retro_serialize_size();
		void *ost = malloc(os);
		if (!retro_serialize(ost, os)) { fprintf(stderr, "re-serialize failed\n"); return 6; }
		FILE *out = fopen(argv[5], "wb"); fwrite(ost, 1, os, out); fclose(out);
		printf("LOAD ok reserialized=%zu\n", os);
	}
	retro_deinit();
	return 0;
}
