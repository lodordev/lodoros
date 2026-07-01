/* cheevos.h — RetroAchievements (softcore) integration for the LodorOS minarch fork.
 *
 * Task #46, Phase B. Vendored rcheevos (rc_client, MIT, v12.3.0) wired into minarch.
 * SOFTCORE ONLY: hardcore is never enabled (no ban exposure, no savestate/Flashback
 * conflict — see lodor-retroachievements-design.md §4). No hardcore toggle exists.
 *
 * minarch's `core`, `screen`, and `font` are file-static, so this is a SEPARATE
 * translation unit that receives what it needs as arguments: the core memory
 * accessors (function pointers) at load, and the SDL surface at render. `font`
 * (api.h: extern GFX_Fonts font) is global, so the toast reads it directly.
 *
 * The five entry points map to these minarch.c hook sites:
 *   CHEEVOS_init()       once at startup (before a game loads)
 *   CHEEVOS_load_game()  Core_load(), after SRAM_read()/RTC_read()
 *   CHEEVOS_do_frame()   main loop + coreThread, right after core.run()
 *   CHEEVOS_render()     video_refresh_callback_main, just before GFX_flip(screen)
 *   CHEEVOS_unload()     Core_quit(), before core.unload_game()
 */
#ifndef CHEEVOS_H
#define CHEEVOS_H

#include <stddef.h>

struct SDL_Surface;

/* Core memory accessors — match minarch's static core.get_memory_data/size, which
 * are libretro's retro_get_memory_data/size. Passed in because `core` is static. */
typedef void*  (*cheevos_mem_data_fn)(unsigned id);
typedef size_t (*cheevos_mem_size_fn)(unsigned id);

/* Bring up rc_client (softcore) and, if RA credentials are stored, log in with the
 * saved token. Safe to call when no credentials exist (becomes a no-op). */
void CHEEVOS_init(void);

/* Identify the loaded game by hash and start the achievement session. core_tag is
 * minarch's core.tag (e.g. "GBA"), mapped here to an RA console id; rom_path is the
 * on-disk ROM/CHD path. Must be called AFTER core.load_game() so memory is valid. */
void CHEEVOS_load_game(const char* core_tag, const char* rom_path,
                       cheevos_mem_data_fn data_fn, cheevos_mem_size_fn size_fn);

/* Per-frame tick: rc_client_do_frame reads memory via the bridge and fires unlock
 * events. Call once per emulated frame, after core.run(). No-op when inactive. */
void CHEEVOS_do_frame(void);

/* Blit any active unlock toast onto minarch's SDL screen surface (its own /dev/fb0
 * path — never show2/say.elf/minui-presenter). Call just before GFX_flip(screen). */
void CHEEVOS_render(struct SDL_Surface* screen);

/* Tear down the session (game unload / app exit). The durable offline queue on disk
 * is left for the next wifi-up drain. */
void CHEEVOS_unload(void);

/* 1 when a session/toast is live — a cheap gate so the render hook can early-out. */
int CHEEVOS_active(void);

#endif /* CHEEVOS_H */
