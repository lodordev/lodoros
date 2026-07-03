// ma_glhw.h — additive OpenGL ES hardware-render path for the LodorOS minarch.
//
// WHY THIS EXISTS
//   The stock LodorOS minarch (picoarch-derived) is software-render only: it
//   never serviced RETRO_ENVIRONMENT_SET_HW_RENDER, so libretro cores that
//   require a GL context (mupen64plus-next, flycast, ppsspp, dolphin, ...) get
//   no framebuffer and refuse to run. This module adds a *self-contained*,
//   *additive* GLES hw-render path so those cores can obtain a real GL context.
//
// DESIGN (deliberately non-invasive)
//   - Offscreen EGL pbuffer context + an FBO (color texture + optional
//     depth/stencil renderbuffer). The core renders INTO our FBO.
//   - On present we glReadPixels the FBO back to RGB565 (vertically flipped to
//     top-left origin) and hand it to the EXISTING software present path
//     (selectScaler/GFX_blitRenderer/GFX_flip). Menus, overlays, OSD and every
//     software core are therefore completely untouched.
//   - The whole module is a no-op unless (a) compiled with -DHAS_GL, (b) a core
//     actually requests SET_HW_RENDER, and (c) the EGL/FBO bring-up succeeds at
//     runtime. Without -DHAS_GL every entry point is a stub returning 0/NULL so
//     minarch links and behaves identically to today on software-only devices
//     (miyoomini/SSD202D, my282/A33) and as a safe fallback everywhere.
//
//   The readback bridge trades some speed (a GPU->CPU stall per frame) for a
//   zero-risk integration that reuses the proven software scaler/present. A
//   direct GL present (SwapWindow / zero-copy) is a documented follow-up that
//   requires owning the display window in the per-device platform layer.
#ifndef MA_GLHW_H
#define MA_GLHW_H

#include "libretro.h"

#ifdef __cplusplus
extern "C" {
#endif

// Called from the SET_HW_RENDER env handler. Records the core's callback and,
// when built with -DHAS_GL, fills cb->get_current_framebuffer and
// cb->get_proc_address. Returns 1 if we will attempt to honor the request
// (HAS_GL compiled in and a supported GLES context type), 0 otherwise (caller
// should then return false to the core so it can pick a software path/fail
// cleanly rather than rendering into nothing).
int GLHW_setHWRender(struct retro_hw_render_callback *cb);

// 1 if a core has requested a (supported) hw context this session.
int GLHW_requested(void);

// 1 once the GL context + FBO exist and the core context_reset has fired.
int GLHW_active(void);

// Create the EGL context + FBO sized to (max_w x max_h) then invoke the core's
// context_reset(). Call once, after retro_load_game()+get_system_av_info().
// Returns 1 on success, 0 on failure (the GL core then cannot render — caller
// should surface an honest error, never a black screen pretending to work).
int GLHW_start(unsigned max_w, unsigned max_h);

// Read the current FBO back into an internal RGB565 buffer, vertically flipped
// to top-left origin. Returns the buffer (owned by this module) and writes the
// row pitch in bytes to *out_pitch. Returns NULL if not active. width/height
// are the core's per-frame dimensions (from the video_refresh callback).
const void *GLHW_readbackRGB565(unsigned width, unsigned height, unsigned *out_pitch);

// Invoke the core context_destroy (if any) and tear down GL/EGL. Safe to call
// when inactive. Call before unloading the core.
void GLHW_stop(void);

#ifdef __cplusplus
}
#endif

#endif // MA_GLHW_H
