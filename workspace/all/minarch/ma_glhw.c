// ma_glhw.c — additive GLES hardware-render path for LodorOS minarch. See ma_glhw.h.
//
// Built only when -DHAS_GL is passed (the GL-capable platforms: A133P tg5040/
// zero28/magicmini, RK3566 my355/rgb30, H700 rg35xxplus). Without -DHAS_GL the
// whole file compiles to stubs so the software-only build (miyoomini, my282)
// and the existing software path are byte-for-byte unaffected.
#include "ma_glhw.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define MA_GL_LOG(...) do { fprintf(stderr, "[ma_glhw] " __VA_ARGS__); fflush(stderr); } while (0)

#ifdef HAS_GL
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

// Fallbacks for enums that may be absent in older GLES2 headers.
#ifndef EGL_OPENGL_ES3_BIT_KHR
#define EGL_OPENGL_ES3_BIT_KHR 0x0040
#endif
#ifndef GL_DEPTH24_STENCIL8
#define GL_DEPTH24_STENCIL8 0x88F0
#endif
#ifndef GL_DEPTH_COMPONENT16
#define GL_DEPTH_COMPONENT16 0x81A5
#endif

static struct retro_hw_render_callback g_cb;
static int      g_have_request = 0;
static int      g_active       = 0;
static int      g_es3          = 0;

static EGLDisplay g_dpy  = EGL_NO_DISPLAY;
static EGLContext g_ctx  = EGL_NO_CONTEXT;
static EGLSurface g_surf = EGL_NO_SURFACE;

static GLuint   g_fbo   = 0;
static GLuint   g_color = 0;
static GLuint   g_depth = 0;
static unsigned g_fbo_w = 0;
static unsigned g_fbo_h = 0;

static uint8_t *g_rgba = NULL; // glReadPixels scratch (RGBA8888)
static uint8_t *g_565  = NULL; // converted output (RGB565)

static uintptr_t glhw_get_current_framebuffer(void) {
    return (uintptr_t)g_fbo;
}
static retro_proc_address_t glhw_get_proc_address(const char *sym) {
    return (retro_proc_address_t)eglGetProcAddress(sym);
}

int GLHW_setHWRender(struct retro_hw_render_callback *cb) {
    if (!cb) return 0;
    enum retro_hw_context_type t = cb->context_type;
    g_es3 = (t == RETRO_HW_CONTEXT_OPENGLES3) ||
            (t == RETRO_HW_CONTEXT_OPENGLES_VERSION && cb->version_major >= 3);
    // We can only provide a GLES context. Desktop-GL requests are remapped to
    // GLES best-effort (most "GL" cores on these SoCs actually use GLES).
    switch (t) {
        case RETRO_HW_CONTEXT_OPENGLES2:
        case RETRO_HW_CONTEXT_OPENGLES3:
        case RETRO_HW_CONTEXT_OPENGLES_VERSION:
            break;
        case RETRO_HW_CONTEXT_OPENGL:
        case RETRO_HW_CONTEXT_OPENGL_CORE:
            MA_GL_LOG("core asked for desktop GL (type %d); attempting GLES — may fail\n", (int)t);
            break;
        default:
            MA_GL_LOG("unsupported hw context type %d (need OpenGL ES); refusing\n", (int)t);
            return 0;
    }
    g_cb = *cb; // keep core-provided context_reset/destroy/depth/stencil/origin
    cb->get_current_framebuffer = glhw_get_current_framebuffer;
    cb->get_proc_address        = (retro_hw_get_proc_address_t)glhw_get_proc_address;
    g_cb.get_current_framebuffer = cb->get_current_framebuffer;
    g_cb.get_proc_address        = cb->get_proc_address;
    g_have_request = 1;
    MA_GL_LOG("SET_HW_RENDER accepted: type=%d v%u.%u depth=%d stencil=%d bottom_left=%d es3=%d\n",
              (int)t, cb->version_major, cb->version_minor,
              cb->depth, cb->stencil, cb->bottom_left_origin, g_es3);
    return 1;
}

int GLHW_requested(void) { return g_have_request; }
int GLHW_active(void)    { return g_active; }

int GLHW_start(unsigned max_w, unsigned max_h) {
    if (!g_have_request) return 0;
    if (g_active) return 1;
    if (max_w == 0) max_w = 640;
    if (max_h == 0) max_h = 480;

    g_dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_dpy == EGL_NO_DISPLAY) { MA_GL_LOG("eglGetDisplay failed\n"); return 0; }
    EGLint emaj = 0, emin = 0;
    if (!eglInitialize(g_dpy, &emaj, &emin)) { MA_GL_LOG("eglInitialize failed 0x%x\n", eglGetError()); return 0; }
    MA_GL_LOG("EGL %d.%d initialized\n", emaj, emin);
    if (!eglBindAPI(EGL_OPENGL_ES_API)) { MA_GL_LOG("eglBindAPI failed\n"); return 0; }

    const EGLint cfg_attr[] = {
        EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, g_es3 ? EGL_OPENGL_ES3_BIT_KHR : EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE,   8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE,  8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE,   g_cb.depth   ? 24 : 0,
        EGL_STENCIL_SIZE, g_cb.stencil ? 8  : 0,
        EGL_NONE
    };
    EGLConfig config; EGLint n = 0;
    if (!eglChooseConfig(g_dpy, cfg_attr, &config, 1, &n) || n < 1) {
        MA_GL_LOG("eglChooseConfig failed (n=%d, 0x%x)\n", n, eglGetError()); return 0;
    }
    const EGLint pb_attr[] = { EGL_WIDTH, (EGLint)max_w, EGL_HEIGHT, (EGLint)max_h, EGL_NONE };
    g_surf = eglCreatePbufferSurface(g_dpy, config, pb_attr);
    if (g_surf == EGL_NO_SURFACE) { MA_GL_LOG("eglCreatePbufferSurface failed 0x%x\n", eglGetError()); return 0; }
    const EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, g_es3 ? 3 : 2, EGL_NONE };
    g_ctx = eglCreateContext(g_dpy, config, EGL_NO_CONTEXT, ctx_attr);
    if (g_ctx == EGL_NO_CONTEXT) { MA_GL_LOG("eglCreateContext failed 0x%x\n", eglGetError()); return 0; }
    if (!eglMakeCurrent(g_dpy, g_surf, g_surf, g_ctx)) { MA_GL_LOG("eglMakeCurrent failed 0x%x\n", eglGetError()); return 0; }
    MA_GL_LOG("GLES context current: %s | %s | %s\n",
              (const char*)glGetString(GL_VENDOR), (const char*)glGetString(GL_RENDERER),
              (const char*)glGetString(GL_VERSION));

    glGenFramebuffers(1, &g_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
    glGenTextures(1, &g_color);
    glBindTexture(GL_TEXTURE_2D, g_color);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, max_w, max_h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g_color, 0);

    if (g_cb.depth) {
        glGenRenderbuffers(1, &g_depth);
        glBindRenderbuffer(GL_RENDERBUFFER, g_depth);
        glRenderbufferStorage(GL_RENDERBUFFER,
            g_cb.stencil ? GL_DEPTH24_STENCIL8 : GL_DEPTH_COMPONENT16, max_w, max_h);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, g_depth);
        if (g_cb.stencil)
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, g_depth);
    }

    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (st != GL_FRAMEBUFFER_COMPLETE) { MA_GL_LOG("FBO incomplete: 0x%x\n", st); return 0; }

    g_fbo_w = max_w; g_fbo_h = max_h;
    g_rgba = (uint8_t*)malloc((size_t)max_w * max_h * 4);
    g_565  = (uint8_t*)malloc((size_t)max_w * max_h * 2);
    if (!g_rgba || !g_565) { MA_GL_LOG("readback buffer alloc failed\n"); return 0; }

    g_active = 1;
    MA_GL_LOG("hw render active: FBO %u (%ux%u)\n", g_fbo, max_w, max_h);
    if (g_cb.context_reset) g_cb.context_reset(); // core uploads shaders/textures here
    return 1;
}

const void *GLHW_readbackRGB565(unsigned width, unsigned height, unsigned *out_pitch) {
    if (!g_active || !g_rgba || !g_565) return NULL;
    if (width  == 0 || height == 0) return NULL;
    if (width  > g_fbo_w) width  = g_fbo_w;
    if (height > g_fbo_h) height = g_fbo_h;

    eglMakeCurrent(g_dpy, g_surf, g_surf, g_ctx);
    glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_RGBA, GL_UNSIGNED_BYTE, g_rgba);

    // GL FBO origin is bottom-left; the software screen wants top-left -> flip rows.
    for (unsigned y = 0; y < height; y++) {
        const uint8_t *src = g_rgba + (size_t)(height - 1 - y) * width * 4;
        uint16_t      *dst = (uint16_t*)(g_565 + (size_t)y * width * 2);
        for (unsigned x = 0; x < width; x++) {
            uint8_t r = src[0], g = src[1], b = src[2];
            src += 4;
            dst[x] = (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
        }
    }
    if (out_pitch) *out_pitch = width * 2;
    return g_565;
}

void GLHW_stop(void) {
    if (!g_have_request) return;
    if (g_active && g_cb.context_destroy) g_cb.context_destroy();
    if (g_dpy != EGL_NO_DISPLAY) {
        eglMakeCurrent(g_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (g_color) { glDeleteTextures(1, &g_color); g_color = 0; }
        if (g_depth) { glDeleteRenderbuffers(1, &g_depth); g_depth = 0; }
        if (g_fbo)   { glDeleteFramebuffers(1, &g_fbo);   g_fbo = 0; }
        if (g_ctx  != EGL_NO_CONTEXT) { eglDestroyContext(g_dpy, g_ctx);  g_ctx  = EGL_NO_CONTEXT; }
        if (g_surf != EGL_NO_SURFACE) { eglDestroySurface(g_dpy, g_surf); g_surf = EGL_NO_SURFACE; }
        eglTerminate(g_dpy);
        g_dpy = EGL_NO_DISPLAY;
    }
    free(g_rgba); g_rgba = NULL;
    free(g_565);  g_565  = NULL;
    g_active = 0; g_have_request = 0;
    MA_GL_LOG("hw render stopped\n");
}

#else  // !HAS_GL — software-only build: every entry point is an inert stub.

int  GLHW_setHWRender(struct retro_hw_render_callback *cb) { (void)cb; return 0; }
int  GLHW_requested(void) { return 0; }
int  GLHW_active(void)    { return 0; }
int  GLHW_start(unsigned max_w, unsigned max_h) { (void)max_w; (void)max_h; return 0; }
const void *GLHW_readbackRGB565(unsigned w, unsigned h, unsigned *p) { (void)w; (void)h; (void)p; return NULL; }
void GLHW_stop(void) {}

#endif // HAS_GL
