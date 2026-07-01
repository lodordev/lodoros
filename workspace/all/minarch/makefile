###########################################################
# RA-enabled minarch makefile (LodorOS fork, task #46 Phase B).
# Drop-in replacement for the minui-build workspace all/minarch/makefile when
# building the RetroAchievements-enabled minarch: adds cheevos.c + the vendored
# rcheevos source set + -DRC_CLIENT_SUPPORTS_HASH. Build context = the workspace
# all/minarch/ dir (needs ../common, ../../$(PLATFORM)/platform, libretro-common,
# and a copy of lodoros/launcher/{cheevos.c,cheevos.h,rcheevos/} alongside).
# rcheevos links STATICALLY (no new NEEDED lib); HTTP is shelled to the device curl.
###########################################################

ifeq (,$(PLATFORM))
PLATFORM=$(UNION_PLATFORM)
endif
ifeq (,$(PLATFORM))
	$(error please specify PLATFORM, eg. PLATFORM=miyoomini make)
endif
ifeq (,$(CROSS_COMPILE))
	$(error missing CROSS_COMPILE for this toolchain)
endif

include ../../$(PLATFORM)/platform/makefile.env
SDL?=SDL

TARGET = minarch

# Vendored rcheevos (MIT, v12.3.0). Excludes rc_client_external.c and
# rc_client_raintegration.c on purpose (RAIntegration is Windows-only toolkit).
RC_SRC = rcheevos/src/rc_compat.c rcheevos/src/rc_client.c rcheevos/src/rc_util.c \
  rcheevos/src/rc_version.c rcheevos/src/rc_libretro.c \
  rcheevos/src/rcheevos/alloc.c rcheevos/src/rcheevos/condition.c rcheevos/src/rcheevos/condset.c \
  rcheevos/src/rcheevos/consoleinfo.c rcheevos/src/rcheevos/format.c rcheevos/src/rcheevos/lboard.c \
  rcheevos/src/rcheevos/memref.c rcheevos/src/rcheevos/operand.c rcheevos/src/rcheevos/rc_validate.c \
  rcheevos/src/rcheevos/richpresence.c rcheevos/src/rcheevos/runtime.c rcheevos/src/rcheevos/runtime_progress.c \
  rcheevos/src/rcheevos/trigger.c rcheevos/src/rcheevos/value.c \
  rcheevos/src/rapi/rc_api_common.c rcheevos/src/rapi/rc_api_editor.c rcheevos/src/rapi/rc_api_info.c \
  rcheevos/src/rapi/rc_api_runtime.c rcheevos/src/rapi/rc_api_user.c \
  rcheevos/src/rhash/md5.c rcheevos/src/rhash/hash.c rcheevos/src/rhash/cdreader.c \
  rcheevos/src/rhash/hash_disc.c rcheevos/src/rhash/hash_rom.c rcheevos/src/rhash/hash_zip.c \
  rcheevos/src/rhash/hash_encrypted.c rcheevos/src/rhash/aes.c

INCDIR = -I. -I./libretro-common/include/ -I../common/ -I../../$(PLATFORM)/platform/ \
  -Ircheevos/include -Ircheevos/src -Ircheevos/src/rcheevos -Ircheevos/src/rapi -Ircheevos/src/rhash
SOURCE = $(TARGET).c cheevos.c $(RC_SRC) ../common/scaler.c ../common/utils.c ../common/api.c ../../$(PLATFORM)/platform/platform.c ma_glhw.c

CC = $(CROSS_COMPILE)gcc
CFLAGS   = $(ARCH) -fomit-frame-pointer
CFLAGS  += $(INCDIR) -DPLATFORM=\"$(PLATFORM)\" -DUSE_$(SDL) -Ofast -std=gnu99
CFLAGS	+= -Os -flto -D_GNU_SOURCE -DRC_CLIENT_SUPPORTS_HASH
LDFLAGS	 = -ldl $(LIBS) -lmsettings -l$(SDL) -l$(SDL)_image -l$(SDL)_ttf -lpthread -lm -lz

# Optional GLES hardware-render path (ma_glhw.c). Enable on GL-capable platforms
# with `make GL=1` (links EGL + GLESv2). Without GL=1, ma_glhw.c compiles to inert
# stubs with no GL dependency, so software-only platforms are byte-unaffected.
ifeq ($(GL),1)
CFLAGS  += -DHAS_GL
LDFLAGS += -lEGL -lGLESv2
endif

BUILD_DATE!=date +%Y.%m.%d
BUILD_HASH!=cat ../../hash.txt
CFLAGS += -DBUILD_DATE=\"${BUILD_DATE}\" -DBUILD_HASH=\"${BUILD_HASH}\"

PRODUCT= build/$(PLATFORM)/$(TARGET).elf

all: libretro-common $(PREFIX)/include/msettings.h
	mkdir -p build/$(PLATFORM)
	$(CC) $(SOURCE) -o $(PRODUCT) $(CFLAGS) $(LDFLAGS)
clean:
	rm -f $(PRODUCT)
libretro-common:
	git clone https://github.com/libretro/libretro-common
$(PREFIX)/include/msettings.h:
	cd /root/workspace/$(PLATFORM)/libmsettings && make
