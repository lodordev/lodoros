/* cheevos.c — RetroAchievements (softcore) integration for the LodorOS minarch fork.
 * Task #46, Phase B. See cheevos.h for the hook map. rcheevos: MIT, v12.3.0.
 *
 * SOFTCORE ONLY — rc_client_set_hardcore_enabled(client,0) and never toggled.
 *
 * SECURITY: the RA token is read from the Lodor config and handed to rc_client; it
 * is NEVER written to a log line or placed on a command line. Server credentials
 * ride in rcheevos's post_data, which we spool to a 0600 temp FILE (curl --data
 * @file) so the token never appears in the process list (ps) the way a -d <data>
 * argument would. The RomM host / RA token are never printed.
 */

#ifndef RC_CLIENT_SUPPORTS_HASH
#define RC_CLIENT_SUPPORTS_HASH
#endif
#include "rc_client.h"
#include "rc_libretro.h"
#include "rc_consoles.h"

#include "defines.h"   /* SDCARD_PATH, SHARED_USERDATA_PATH, PLATFORM, MAX_PATH */
#include "api.h"       /* GFX_*, GFX_Fonts font, SDL types */

#include "cheevos.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <strings.h> /* strcasecmp */

#ifndef RETRO_MEMORY_SYSTEM_RAM
#define RETRO_MEMORY_SYSTEM_RAM 2
#endif

/* User-Agent for RA version negotiation. Kept in lockstep with the engine's
 * ra.UserAgent ("LodorOS/0.1") so the login (Go) and in-game client present one
 * identity to the RA server. Bump together on releases. */
#define CHEEVOS_USER_AGENT "LodorOS/0.1"

/* Durable evidence / offline-safety log (the full offline drain is a deferred phase,
 * design §5). One earned unlock per line so a power-off never silently loses one. */
#define CHEEVOS_DIR        SHARED_USERDATA_PATH "/lodor-cheevos"
#define CHEEVOS_UNLOCK_LOG CHEEVOS_DIR "/unlocks.log"

/* ---- module state -------------------------------------------------------- */
static rc_client_t*                  s_client = NULL;
static rc_libretro_memory_regions_t  s_memory;
static int                           s_memory_ready = 0;
static cheevos_mem_data_fn           s_data_fn = NULL;
static cheevos_mem_size_fn           s_size_fn = NULL;

static char s_toast_title[160];
static int  s_toast_frames = 0;   /* countdown; ~240 frames ~= 4s @60fps */

/* ===========================================================================
 * Credential read — pull {ra_username, ra_token} from the Lodor config.json.
 * Path: $LODOR_CONFIG when the launcher exports it (preferred, decoupled), else a
 * small candidate list under Tools/<PLATFORM>/. Minimal string scan (top-level
 * keys), not a full JSON parser — matches the launcher's existing flat-key style.
 * =========================================================================== */
static char* cheevos_read_file(const char* path, long* out_len) {
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0 || n > (16 * 1024 * 1024)) { fclose(f); return NULL; }
    char* buf = (char*)malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t rd = fread(buf, 1, (size_t)n, f);
    fclose(f);
    buf[rd] = 0;
    if (out_len) *out_len = (long)rd;
    return buf;
}

/* Extract the string value of a top-level JSON key: finds "key" then the first
 * "..." after the following ':'. Good enough for ra_username/ra_token (plain
 * strings, no escapes in practice). Returns 1 on success. */
static int cheevos_json_str(const char* buf, const char* key, char* out, size_t outsz) {
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char* p = strstr(buf, needle);
    if (!p) return 0;
    p = strchr(p + strlen(needle), ':');
    if (!p) return 0;
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p != '"') return 0;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < outsz) out[i++] = *p++;
    out[i] = 0;
    return i > 0;
}

static int cheevos_load_credentials(char* user, size_t user_sz, char* token, size_t token_sz) {
    const char* candidates[4];
    int n = 0;
    const char* env = getenv("LODOR_CONFIG");
    if (env && *env) candidates[n++] = env;
    candidates[n++] = SDCARD_PATH "/Tools/" PLATFORM "/Lodor.pak/config.json";
    candidates[n++] = SDCARD_PATH "/Tools/" PLATFORM "/RomM Sync.pak/config.json";
    candidates[n++] = SDCARD_PATH "/Tools/" PLATFORM "/Grout.pak/config.json";
    for (int i = 0; i < n; i++) {
        long len = 0;
        char* buf = cheevos_read_file(candidates[i], &len);
        if (!buf) continue;
        int ok = cheevos_json_str(buf, "ra_username", user, user_sz)
              && cheevos_json_str(buf, "ra_token", token, token_sz);
        free(buf);
        if (ok) return 1;
    }
    return 0;
}

/* ===========================================================================
 * RA launcher toggles — RA_ENABLE / RA_HARDCORE from Lodor.pak/settings.conf, the
 * SAME flat key=val file the launcher's "RetroAchievements (ON/OFF)" + "Hardcore
 * (ON/OFF)" rows write (minui.c Lodor_writeRASettings). Read here so the in-process
 * minarch RA client honors them without a launcher round-trip. Defaults match the
 * launcher: RA on (1), hardcore OFF (0).
 *
 * HARDCORE CAVEAT (minarch): minarch ships savestates/rewind and does NOT notify
 * rc_client when a state is loaded, so a hardcore session here is not enforce-clean
 * the way RetroArch/flycast/PPSSPP enforce it (those gate savestates under hardcore).
 * The toggle is honored for parity, but hardcore is best left to the standalone /
 * RetroArch paks. Default OFF for exactly this reason.
 * =========================================================================== */
static void cheevos_read_ra_settings(int* enable, int* hardcore) {
    *enable = 1; *hardcore = 0;   /* defaults mirror the launcher */
    const char* path = SDCARD_PATH "/Tools/" PLATFORM "/Lodor.pak/settings.conf";
    long len = 0;
    char* buf = cheevos_read_file(path, &len);
    if (!buf) return;
    /* line-oriented scan; tolerant of CRLF and surrounding whitespace */
    char* save = NULL;
    for (char* line = strtok_r(buf, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        int v;
        if (sscanf(line, " RA_ENABLE=%d", &v) == 1)   *enable   = v ? 1 : 0;
        else if (sscanf(line, " RA_HARDCORE=%d", &v) == 1) *hardcore = v ? 1 : 0;
    }
    free(buf);
}

/* ===========================================================================
 * Console-id map: minarch core.tag -> RC_CONSOLE_*. Covers the LodorOS Emus set.
 * Unknown tags fall back to RC_CONSOLE_UNKNOWN (rcheevos can still hash-identify
 * many ROM-based systems). On-device validation owed per the design §9.
 * =========================================================================== */
static uint32_t cheevos_console_for_tag(const char* tag) {
    if (!tag) return RC_CONSOLE_UNKNOWN;
    struct { const char* t; uint32_t c; } map[] = {
        {"GBA", RC_CONSOLE_GAMEBOY_ADVANCE}, {"MGBA", RC_CONSOLE_GAMEBOY_ADVANCE},
        {"GBC", RC_CONSOLE_GAMEBOY_COLOR},   {"GB", RC_CONSOLE_GAMEBOY},
        {"FC", RC_CONSOLE_NINTENDO},         {"NES", RC_CONSOLE_NINTENDO},
        {"FDS", RC_CONSOLE_NINTENDO},        {"PKM", RC_CONSOLE_NINTENDO},
        {"SFC", RC_CONSOLE_SUPER_NINTENDO},  {"SNES", RC_CONSOLE_SUPER_NINTENDO},
        {"MD", RC_CONSOLE_MEGA_DRIVE},       {"GEN", RC_CONSOLE_MEGA_DRIVE},
        {"SMS", RC_CONSOLE_MASTER_SYSTEM},   {"GG", RC_CONSOLE_GAME_GEAR},
        {"SEGACD", RC_CONSOLE_SEGA_CD},      {"32X", RC_CONSOLE_SEGA_32X},
        {"PCE", RC_CONSOLE_PC_ENGINE},       {"PCECD", RC_CONSOLE_PC_ENGINE},
        {"LYNX", RC_CONSOLE_ATARI_LYNX},     {"NGP", RC_CONSOLE_NEOGEO_POCKET},
        {"NGPC", RC_CONSOLE_NEOGEO_POCKET},  {"VB", RC_CONSOLE_VIRTUAL_BOY},
        {"WS", RC_CONSOLE_WONDERSWAN},       {"WSC", RC_CONSOLE_WONDERSWAN},
        {"PS", RC_CONSOLE_PLAYSTATION},      {"PSX", RC_CONSOLE_PLAYSTATION},
    };
    for (size_t i = 0; i < sizeof(map)/sizeof(map[0]); i++)
        if (strcasecmp(tag, map[i].t) == 0) return map[i].c;
    return RC_CONSOLE_UNKNOWN;
}

/* ===========================================================================
 * Memory bridge — rc_client read_memory via rc_libretro region mapping.
 * minarch captures no SET_MEMORY_MAPS (see minarch.c environment_callback), so we
 * use the get_core_memory_info fallback (SYSTEM_RAM/SAVE_RAM), which is what RA
 * needs for the consoles it targets here.
 * =========================================================================== */
static void cheevos_core_memory_info(uint32_t id, rc_libretro_core_memory_info_t* info) {
    info->data = s_data_fn ? (uint8_t*)s_data_fn(id) : NULL;
    info->size = s_size_fn ? s_size_fn(id) : 0;
}

static uint32_t cheevos_read_memory(uint32_t address, uint8_t* buffer, uint32_t num_bytes, rc_client_t* client) {
    (void)client;
    if (!s_memory_ready) return 0;
    return rc_libretro_memory_read(&s_memory, address, buffer, num_bytes);
}

/* ===========================================================================
 * HTTP transport — synchronous curl, credentials spooled to a 0600 temp file.
 * Reuses the device curl the RomM pak already ships. The call is synchronous so
 * rc_client's async login/identify chains complete inline (each next request is
 * issued from the prior callback). On no-network curl returns http 0 -> rc_client
 * treats it as retryable.
 * =========================================================================== */
static void cheevos_server_call(const rc_api_request_t* request,
                                rc_client_server_callback_t callback,
                                void* callback_data, rc_client_t* client) {
    (void)client;
    const char* respfile = "/tmp/.lodor-ra-resp";
    const char* postfile = "/tmp/.lodor-ra-post";
    char cmd[4096];

    if (request->post_data && request->post_data[0]) {
        FILE* pf = fopen(postfile, "w");
        if (pf) { fputs(request->post_data, pf); fclose(pf); }
        snprintf(cmd, sizeof(cmd),
            "curl -s -m 30 -A '%s' -o '%s' -w '%%{http_code}' --data-binary @'%s' '%s'",
            CHEEVOS_USER_AGENT, respfile, postfile, request->url);
    } else {
        snprintf(cmd, sizeof(cmd),
            "curl -s -m 30 -A '%s' -o '%s' -w '%%{http_code}' '%s'",
            CHEEVOS_USER_AGENT, respfile, request->url);
    }

    int http = 0;
    FILE* p = popen(cmd, "r");
    if (p) {
        char code[16] = {0};
        if (fgets(code, sizeof(code), p)) http = atoi(code);
        pclose(p);
    }

    long blen = 0;
    char* body = cheevos_read_file(respfile, &blen);

    rc_api_server_response_t response;
    memset(&response, 0, sizeof(response));
    response.body = body ? body : "";
    response.body_length = body ? (size_t)blen : 0;
    /* curl failure (no network / curl absent) -> http stays 0; flag it retryable so
     * rc_client keeps unlocks queued rather than discarding them. */
    response.http_status_code = http ? http : RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR;

    callback(&response, callback_data);
    if (body) free(body);
    remove(postfile);
}

/* ===========================================================================
 * Toast — drawn onto minarch's own SDL screen (its /dev/fb0 path), NOT
 * show2/say.elf/minui-presenter (those corrupt the Flip fb). A filled bar +
 * GFX_blitText using the global `font`. NOTE(device): exact bar geometry/color and
 * whether the BPreplay font carries the trophy glyph are on-hardware polish items.
 * =========================================================================== */
static void cheevos_queue_toast(const char* prefix, const char* title) {
    snprintf(s_toast_title, sizeof(s_toast_title), "%s %s",
             prefix ? prefix : "", title ? title : "");
    s_toast_frames = 240;
}

void CHEEVOS_render(struct SDL_Surface* sdl_screen) {
    if (s_toast_frames <= 0 || !sdl_screen) return;
    s_toast_frames--;

    SDL_Surface* screen = (SDL_Surface*)sdl_screen;
    int tw = 0, th = 0;
    GFX_sizeText(font.medium, s_toast_title, 0, &tw, &th);

    int pad = 12;
    int barh = th + pad * 2;
    int barw = tw + pad * 2;
    if (barw > screen->w) barw = screen->w;
    int x = (screen->w - barw) / 2;
    int y = pad;

    SDL_Rect bar = { x, y, barw, barh };
    SDL_FillRect(screen, &bar, SDL_MapRGB(screen->format, 24, 24, 28));

    SDL_Color white = { 255, 255, 255 };
    SDL_Rect tr = { x + pad, y + pad, tw, th };
    GFX_blitText(font.medium, s_toast_title, 0, white, screen, &tr);
}

/* ===========================================================================
 * Event handler — unlocks (toast + durable log). Softcore only.
 * =========================================================================== */
static void cheevos_log_unlock(const rc_client_achievement_t* ach) {
    system("mkdir -p \"" CHEEVOS_DIR "\" 2>/dev/null");
    FILE* f = fopen(CHEEVOS_UNLOCK_LOG, "a");
    if (!f) return;
    fprintf(f, "%u\t%s\n", ach->id, ach->title ? ach->title : "");
    fclose(f);
}

static void cheevos_event_handler(const rc_client_event_t* event, rc_client_t* client) {
    (void)client;
    switch (event->type) {
    case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
        if (event->achievement) {
            cheevos_queue_toast("\xF0\x9F\x8F\x86", event->achievement->title); /* trophy + title */
            cheevos_log_unlock(event->achievement);
        }
        break;
    case RC_CLIENT_EVENT_GAME_COMPLETED:
        cheevos_queue_toast("\xF0\x9F\x8F\x86", "Mastered!");
        break;
    default:
        break;
    }
}

/* ===========================================================================
 * Lifecycle
 * =========================================================================== */
static void cheevos_login_cb(int result, const char* error_message, rc_client_t* c, void* u) {
    (void)c; (void)u;
    /* Host-free, token-free: log only the rc result code, never the message body
     * (which can echo request context) nor any credential. */
    if (result == RC_OK) LOG_info("cheevos: RA login ok\n");
    else                 LOG_info("cheevos: RA login failed (rc=%d)\n", result);
}

void CHEEVOS_init(void) {
    if (s_client) return;

    /* Honor the launcher toggles: RA_ENABLE gates the whole client, RA_HARDCORE picks
     * the mode. RA_ENABLE=0 -> RA fully inert this session (no client, no login). */
    int ra_enable = 1, ra_hardcore = 0;
    cheevos_read_ra_settings(&ra_enable, &ra_hardcore);
    if (!ra_enable) {
        LOG_info("cheevos: RA disabled in settings (RA_ENABLE=0) — inactive this session\n");
        return;
    }

    s_client = rc_client_create(cheevos_read_memory, cheevos_server_call);
    if (!s_client) return;
    rc_client_set_event_handler(s_client, cheevos_event_handler);

    /* Default SOFTCORE (no ban exposure, no Flashback/savestate conflict). Hardcore is
     * opt-in via the launcher's "Hardcore (ON/OFF)" row; see the CAVEAT on
     * cheevos_read_ra_settings — minarch does not gate savestates under hardcore, so
     * this is parity-only and best left off here. */
    rc_client_set_hardcore_enabled(s_client, ra_hardcore ? 1 : 0);

    char user[128] = {0}, token[256] = {0};
    if (cheevos_load_credentials(user, sizeof(user), token, sizeof(token))) {
        LOG_info("cheevos: RA %s mode\n", ra_hardcore ? "HARDCORE" : "softcore");
        rc_client_begin_login_with_token(s_client, user, token, cheevos_login_cb, NULL);
    } else {
        LOG_info("cheevos: no RA credentials stored — RA inactive this session\n");
    }
    /* token/user buffers go out of scope; nothing logged. */
}

static void cheevos_load_cb(int result, const char* error_message, rc_client_t* c, void* u) {
    (void)error_message; (void)u;
    if (result == RC_OK) {
        const rc_client_game_t* g = rc_client_get_game_info(c);
        LOG_info("cheevos: game loaded (%s)\n", g && g->title ? g->title : "?");
    } else {
        /* RC_NO_GAME_LOADED / not-found: silent inactive, no toast, no error noise. */
        LOG_info("cheevos: no RA set for this game (rc=%d)\n", result);
    }
}

void CHEEVOS_load_game(const char* core_tag, const char* rom_path,
                       cheevos_mem_data_fn data_fn, cheevos_mem_size_fn size_fn) {
    if (!s_client || !rom_path) return;
    s_data_fn = data_fn;
    s_size_fn = size_fn;

    uint32_t console = cheevos_console_for_tag(core_tag);
    /* mmap=NULL: minarch has no SET_MEMORY_MAPS; the get_core_memory_info fallback
     * supplies SYSTEM_RAM/SAVE_RAM. */
    s_memory_ready = (rc_libretro_memory_init(&s_memory, NULL,
                        cheevos_core_memory_info, console) != 0);

    rc_client_begin_identify_and_load_game(s_client, console, rom_path,
        NULL, 0, cheevos_load_cb, NULL);
}

void CHEEVOS_do_frame(void) {
    if (s_client && s_memory_ready) rc_client_do_frame(s_client);
}

void CHEEVOS_unload(void) {
    if (s_memory_ready) { rc_libretro_memory_destroy(&s_memory); s_memory_ready = 0; }
    /* Keep s_client across games within one minarch run; rc_client_unload_game
     * resets the session. Full teardown happens at process exit. */
    if (s_client) rc_client_unload_game(s_client);
    s_toast_frames = 0;
}

int CHEEVOS_active(void) {
    return (s_client && (s_toast_frames > 0 || s_memory_ready)) ? 1 : 0;
}
