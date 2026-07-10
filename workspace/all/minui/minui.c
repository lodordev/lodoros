#include <stdio.h>
#include <stdlib.h>
#include <msettings.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>
#include <ctype.h>
#include <strings.h>
#include <sys/utsname.h> // lodor: uname() for shared-dir Tailscale arch probe // strncasecmp (lodor onboarding subpath scheme-strip)
#include <unistd.h>
#include <fcntl.h>
#include <time.h> // lodor: local-play timestamp for the Continue tile
#include <sys/statvfs.h> // lodor: SD free/used for the Sync menu storage header (Smart Delete on-ramp)

#include "defines.h"
#include "api.h"
#include "utils.h"
#include "qrcodegen.h" // lodor §tailscale: Nayuki QR Code generator (MIT) for the Tailscale sign-in QR

///////////////////////////////////////

typedef struct Array {
	int count;
	int capacity;
	void** items;
} Array;

static Array* Array_new(void) {
	Array* self = malloc(sizeof(Array));
	self->count = 0;
	self->capacity = 8;
	self->items = malloc(sizeof(void*) * self->capacity);
	return self;
}
static void Array_push(Array* self, void* item) {
	if (self->count>=self->capacity) {
		self->capacity *= 2;
		self->items = realloc(self->items, sizeof(void*) * self->capacity);
	}
	self->items[self->count++] = item;
}
static void Array_unshift(Array* self, void* item) {
	if (self->count==0) return Array_push(self, item);
	Array_push(self, NULL); // ensures we have enough capacity
	for (int i=self->count-2; i>=0; i--) {
		self->items[i+1] = self->items[i];
	}
	self->items[0] = item;
}
static void* Array_pop(Array* self) {
	if (self->count==0) return NULL;
	return self->items[--self->count];
}
static void Array_reverse(Array* self) {
	int end = self->count-1;
	int mid = self->count/2;
	for (int i=0; i<mid; i++) {
		void* item = self->items[i];
		self->items[i] = self->items[end-i];
		self->items[end-i] = item;
	}
}
static void Array_free(Array* self) {
	free(self->items); 
	free(self);
}

static int StringArray_indexOf(Array* self, char* str) {
	for (int i=0; i<self->count; i++) {
		if (exactMatch(self->items[i], str)) return i;
	}
	return -1;
}
static void StringArray_free(Array* self) {
	for (int i=0; i<self->count; i++) {
		free(self->items[i]);
	}
	Array_free(self);
}

///////////////////////////////////////

typedef struct Hash {
	Array* keys;
	Array* values;
} Hash; // not really a hash

static Hash* Hash_new(void) {
	Hash* self = malloc(sizeof(Hash));
	self->keys = Array_new();
	self->values = Array_new();
	return self;
}
static void Hash_free(Hash* self) {
	StringArray_free(self->keys);
	StringArray_free(self->values);
	free(self);
}
static void Hash_set(Hash* self, char* key, char* value) {
	Array_push(self->keys, strdup(key));
	Array_push(self->values, strdup(value));
}
static char* Hash_get(Hash* self, char* key) {
	int i = StringArray_indexOf(self->keys, key);
	if (i==-1) return NULL;
	return self->values->items[i];
}

///////////////////////////////////////

enum EntryType {
	ENTRY_DIR,
	ENTRY_PAK,
	ENTRY_ROM,
};
typedef struct Entry {
	char* path;
	char* name;
	char* unique;
	int type;
	int alpha; // index in parent Directory's alphas Array, which points to the index of an Entry in its entries Array :sweat_smile:
} Entry;

static Entry* Entry_new(char* path, int type) {
	char display_name[256];
	getDisplayName(path, display_name);
	Entry* self = malloc(sizeof(Entry));
	self->path = strdup(path);
	self->name = strdup(display_name);
	self->unique = NULL;
	self->type = type;
	self->alpha = 0;
	return self;
}
static void Entry_free(Entry* self) {
	free(self->path);
	free(self->name);
	if (self->unique) free(self->unique);
	free(self);
}

static int EntryArray_indexOf(Array* self, char* path) {
	for (int i=0; i<self->count; i++) {
		Entry* entry = self->items[i];
		if (exactMatch(entry->path, path)) return i;
	}
	return -1;
}
static int EntryArray_sortEntry(const void* a, const void* b) {
	Entry* item1 = *(Entry**)a;
	Entry* item2 = *(Entry**)b;
	return strcasecmp(item1->name, item2->name);
}
static void EntryArray_sort(Array* self) {
	qsort(self->items, self->count, sizeof(void*), EntryArray_sortEntry);
}

static void EntryArray_free(Array* self) {
	for (int i=0; i<self->count; i++) {
		Entry_free(self->items[i]);
	}
	Array_free(self);
}

///////////////////////////////////////

#define INT_ARRAY_MAX 27
typedef struct IntArray {
	int count;
	int items[INT_ARRAY_MAX];
} IntArray;
static IntArray* IntArray_new(void) {
	IntArray* self = malloc(sizeof(IntArray));
	self->count = 0;
	memset(self->items, 0, sizeof(int) * INT_ARRAY_MAX);
	return self;
}
static void IntArray_push(IntArray* self, int i) {
	self->items[self->count++] = i;
}
static void IntArray_free(IntArray* self) {
	free(self);
}

///////////////////////////////////////

typedef struct Directory {
	char* path;
	char* name;
	Array* entries;
	IntArray* alphas;
	// rendering
	int selected;
	int start;
	int end;
} Directory;

static int getIndexChar(char* str) {
	char i = 0;
	char c = tolower(str[0]);
	if (c>='a' && c<='z') i = (c-'a')+1;
	return i;
}

static void getUniqueName(Entry* entry, char* out_name) {
	char* filename = strrchr(entry->path, '/')+1;
	char emu_tag[256];
	getEmuName(entry->path, emu_tag);
	
	char *tmp;
	strcpy(out_name, entry->name);
	tmp = out_name + strlen(out_name);
	strcpy(tmp, " (");
	tmp = out_name + strlen(out_name);
	strcpy(tmp, emu_tag);
	tmp = out_name + strlen(out_name);
	strcpy(tmp, ")");
}

static void Directory_index(Directory* self) {
	int is_collection = prefixMatch(COLLECTIONS_PATH, self->path);
	int skip_index = exactMatch(FAUX_RECENT_PATH, self->path) || is_collection; // not alphabetized
	
	Hash* map = NULL;
	char map_path[256];
	sprintf(map_path, "%s/map.txt", is_collection ? COLLECTIONS_PATH : self->path);
	if (exists(map_path)) {
		FILE* file = fopen(map_path, "r");
		if (file) {
			map = Hash_new();
			char line[256];
			while (fgets(line,256,file)!=NULL) {
				normalizeNewline(line);
				trimTrailingNewlines(line);
				if (strlen(line)==0) continue; // skip empty lines

				char* tmp = strchr(line,'\t');
				if (tmp) {
					tmp[0] = '\0';
					char* key = line;
					char* value = tmp+1;
					Hash_set(map, key, value);
				}
			}
			fclose(file);
			
			int resort = 0;
			int filter = 0;
			for (int i=0; i<self->entries->count; i++) {
				Entry* entry = self->entries->items[i];
				char* filename = strrchr(entry->path, '/')+1;
				char* alias = Hash_get(map, filename);
				if (alias) {
					free(entry->name);
					entry->name = strdup(alias);
					resort = 1;
					if (!filter && hide(entry->name)) filter = 1;
				}
			}
			
			if (filter) {
				Array* entries = Array_new();
				for (int i=0; i<self->entries->count; i++) {
					Entry* entry = self->entries->items[i];
					if (hide(entry->name)) {
						Entry_free(entry);
					}
					else {
						Array_push(entries, entry);
					}
				}
				Array_free(self->entries); // not EntryArray_free because we've just moved the entries from the original to the filtered one!
				self->entries = entries;
			}
			if (resort) EntryArray_sort(self->entries);
		}
	}
	
	Entry* prior = NULL;
	int alpha = -1;
	int index = 0;
	for (int i=0; i<self->entries->count; i++) {
		Entry* entry = self->entries->items[i];
		if (map) {
			char* filename = strrchr(entry->path, '/')+1;
			char* alias = Hash_get(map, filename);
			if (alias) {
				free(entry->name);
				entry->name = strdup(alias);
			}
		}
		
		if (prior!=NULL && exactMatch(prior->name, entry->name)) {
			if (prior->unique) free(prior->unique);
			if (entry->unique) free(entry->unique);
			
			char* prior_filename = strrchr(prior->path, '/')+1;
			char* entry_filename = strrchr(entry->path, '/')+1;
			if (exactMatch(prior_filename, entry_filename)) {
				char prior_unique[256];
				char entry_unique[256];
				getUniqueName(prior, prior_unique);
				getUniqueName(entry, entry_unique);
				
				prior->unique = strdup(prior_unique);
				entry->unique = strdup(entry_unique);
			}
			else {
				prior->unique = strdup(prior_filename);
				entry->unique = strdup(entry_filename);
			}
		}

		if (!skip_index) {
			int a = getIndexChar(entry->name);
			if (a!=alpha) {
				index = self->alphas->count;
				IntArray_push(self->alphas, i);
				alpha = a;
			}
			entry->alpha = index;
		}
		
		prior = entry;
	}
	
	if (map) Hash_free(map);
}

static Array* getRoot(void);
static Array* getRecents(void);
static Array* getCollection(char* path);
static Array* getDiscs(char* path);
static Array* getEntries(char* path);

static Directory* Directory_new(char* path, int selected) {
	char display_name[256];
	getDisplayName(path, display_name);
	
	Directory* self = malloc(sizeof(Directory));
	self->path = strdup(path);
	self->name = strdup(display_name);
	if (exactMatch(path, SDCARD_PATH)) {
		self->entries = getRoot();
	}
	else if (exactMatch(path, FAUX_RECENT_PATH)) {
		self->entries = getRecents();
	}
	else if (!exactMatch(path, COLLECTIONS_PATH) && prefixMatch(COLLECTIONS_PATH, path) && suffixMatch(".txt", path)) {
		self->entries = getCollection(path);
	}
	else if (suffixMatch(".m3u", path)) {
		self->entries = getDiscs(path);
	}
	else {
		self->entries = getEntries(path);
	}
	self->alphas = IntArray_new();
	self->selected = selected;
	Directory_index(self);
	return self;
}
static void Directory_free(Directory* self) {
	free(self->path);
	free(self->name);
	EntryArray_free(self->entries);
	IntArray_free(self->alphas);
	free(self);
}

static void DirectoryArray_pop(Array* self) {
	Directory_free(Array_pop(self));
}
static void DirectoryArray_free(Array* self) {
	for (int i=0; i<self->count; i++) {
		Directory_free(self->items[i]);
	}
	Array_free(self);
}

///////////////////////////////////////

typedef struct Recent {
	char* path; // NOTE: this is without the SDCARD_PATH prefix!
	char* alias;
	int available;
} Recent;
 // yiiikes
static char* recent_alias = NULL;

// lodor §override (#144): per-game emulator override, layered on top of the folder-tag
// default. Resolution order: sidecar pak= (if that pak exists) -> folder-tag default
// (getEmuPath). The sidecar is a tiny text file:
//   $SHARED_USERDATA_PATH/.minui/<TAG>/<rom_file>.emu.txt
//   lines: pak=<PAKNAME>            (e.g. GBA-SUPER — a pak under either pak root)
//          core=<stem>              (optional: minarch core stem, exported to launch.sh)
// TAG is ALWAYS the ROM's FOLDER tag (never the variant) — save-path integrity: states,
// saves and .minui bookkeeping stay keyed by the folder tag no matter which pak runs the
// game (LODOR_ROM_TAG is exported at launch so first-party launch.sh derive EMU_TAG from
// it instead of their own pak name).
static const char* Lodor_stripMarker(const char* base); // defined with the Continue machinery below
static void Lodor_romTag(const char* rom_path, char* out_tag) { // out_tag: MAX_PATH
	getEmuName(rom_path, out_tag); // MinUI's tag extraction IS the folder-tag rule
}
static void Lodor_emuSidecarPath(const char* rom_path, char* out, size_t outsz) {
	out[0] = '\0';
	char tag[MAX_PATH];
	Lodor_romTag(rom_path, tag);
	const char* slash = strrchr(rom_path, '/');
	if (!tag[0] || !slash || !slash[1]) return;
	// marker-AGNOSTIC filename: a ✘-stub download renames the on-disk file (marker flip),
	// and the override must survive that — key the sidecar by the canonical basename.
	snprintf(out, outsz, "%s/.minui/%s/%s.emu.txt", SHARED_USERDATA_PATH, tag, Lodor_stripMarker(slash+1));
}
// §override (#144/#163) SECURITY: validate a sidecar pak=/core= VALUE before trusting it.
// The sidecar is on-card (garble/attacker-influenceable) and its value later rides an eval'd
// launch command; a bad value must degrade to the default emulator, never smash the stack or
// inject shell. A legitimate stem is a single filename component: pak names (MGBA, PCSX-ReARMed,
// gpSP, folder tags with spaces/parens) and core stems. We therefore accept any printable byte
// EXCEPT the path separator '/' and control chars, cap the length well under the caller buffers,
// and require at least one non-space character. Deliberately permissive on the printable set so
// a normal override keeps working — the escaping layer (escapeSingleQuotes) is what neutralizes
// quotes; this gate just rejects the implausible/dangerous.
#define LODOR_SIDECAR_MAX 120 // stems are short; well under the 128B pakname / 256B core buffers
static int Lodor_validStem(const char* v) {
	if (!v || !v[0]) return 0;
	size_t len = strlen(v);
	if (len > LODOR_SIDECAR_MAX) return 0;
	int printable = 0;
	for (const unsigned char* p = (const unsigned char*)v; *p; p++) {
		if (*p < 0x20 || *p == 0x7F) return 0; // control chars (incl. embedded NL/CR/TAB)
		if (*p == '/') return 0;               // a stem is one component, never a path
		if (*p != ' ') printable = 1;
	}
	return printable;
}
// parse the sidecar; either out may be NULL. Returns 1 if the file exists and parsed.
static int Lodor_readEmuSidecar(const char* rom_path, char* out_pak, size_t paksz, char* out_core, size_t coresz) {
	if (out_pak) out_pak[0] = '\0';
	if (out_core) out_core[0] = '\0';
	char sc[MAX_PATH];
	Lodor_emuSidecarPath(rom_path, sc, sizeof(sc));
	if (!sc[0]) return 0;
	FILE* f = fopen(sc, "r");
	if (!f) return 0;
	char line[256];
	while (fgets(line, sizeof(line), f)) {
		normalizeNewline(line);
		trimTrailingNewlines(line);
		// §override (#163): only accept a value that passes Lodor_validStem — a rejected value
		// leaves the out buffer empty, so the resolver falls back to the folder-tag default.
		if (out_pak  && strncmp(line, "pak=",  4)==0 && Lodor_validStem(line+4))  { strncpy(out_pak,  line+4, paksz-1);  out_pak[paksz-1]='\0'; }
		if (out_core && strncmp(line, "core=", 5)==0 && Lodor_validStem(line+5))  { strncpy(out_core, line+5, coresz-1); out_core[coresz-1]='\0'; }
	}
	fclose(f);
	return 1;
}
// core= from the LAST resolve (openRom/autoResume consume it right after resolving —
// single-threaded launch path, same lifetime pattern as recent_alias above).
static char lodor_core_override[256] = "";
// try <PAKNAME>.pak under both pak roots (device-specific SDCARD root first, matching
// getEmuPath's preference order). Returns 1 + fills pak_path when found.
static int Lodor_findPak(const char* pakname, char* pak_path) { // pak_path: 256
	snprintf(pak_path, 256, "%s/Emus/%s/%s.pak/launch.sh", SDCARD_PATH, PLATFORM, pakname);
	if (exists(pak_path)) return 1;
	snprintf(pak_path, 256, "%s/Emus/%s.pak/launch.sh", PAKS_PATH, pakname);
	return exists(pak_path);
}
// THE resolver — wraps getEmuPath. Every launch path routes through here so a sidecar
// override applies uniformly (openRom, autoResume, recents availability). Falls back to
// the folder-tag default when the sidecar (or the pak it names) is missing — graceful,
// never blocks a launch. Side effect: (re)fills lodor_core_override for this ROM.
static void Lodor_resolveEmu(const char* rom_path, char* out_pak_path) { // out: 256
	char tag[MAX_PATH];
	Lodor_romTag(rom_path, tag);
	char pakname[128];
	Lodor_readEmuSidecar(rom_path, pakname, sizeof(pakname), lodor_core_override, sizeof(lodor_core_override));
	if (pakname[0]) {
		if (Lodor_findPak(pakname, out_pak_path)) return;
		lodor_core_override[0] = '\0'; // named pak is gone -> the core stem is meaningless too
	}
	getEmuPath(tag, out_pak_path);
}
// availability for THIS rom (sidecar-aware hasEmu) — a recent stays playable when its
// override pak exists even if the stock default pak was removed, and vice versa.
static int Lodor_hasEmuFor(const char* sd_rom_path) {
	char pak_path[256];
	Lodor_resolveEmu(sd_rom_path, pak_path);
	return exists(pak_path);
}

static int hasEmu(char* emu_name);
static Recent* Recent_new(char* path, char* alias) {
	Recent* self = malloc(sizeof(Recent));

	char sd_path[256]; // only need to get emu name
	sprintf(sd_path, "%s%s", SDCARD_PATH, path);

	self->path = strdup(path);
	self->alias = alias ? strdup(alias) : NULL;
	self->available = Lodor_hasEmuFor(sd_path); // §override (#144): sidecar-aware availability
	return self;
}
static void Recent_free(Recent* self) {
	free(self->path);
	if (self->alias) free(self->alias);
	free(self);
}

static int RecentArray_indexOf(Array* self, char* str) {
	for (int i=0; i<self->count; i++) {
		Recent* item = self->items[i];
		if (exactMatch(item->path, str)) return i;
	}
	return -1;
}
static void RecentArray_free(Array* self) {
	for (int i=0; i<self->count; i++) {
		Recent_free(self->items[i]);
	}
	Array_free(self);
}

///////////////////////////////////////

static Directory* top;
static Array* stack; // DirectoryArray
static Array* recents; // RecentArray

static int quit = 0;
static int can_resume = 0;
static int should_resume = 0; // set to 1 on BTN_RESUME but only if can_resume==1
static int simple_mode = 0;
static char slot_path[256];

static int restore_depth = -1;
static int restore_relative = -1;
static int restore_selected = 0;
static int restore_start = 0;
static int restore_end = 0;

///////////////////////////////////////

#define MAX_RECENTS 24 // a multiple of all menu rows
static void saveRecents(void) {
	FILE* file = fopen(RECENT_PATH, "w");
	if (file) {
		for (int i=0; i<recents->count; i++) {
			Recent* recent = recents->items[i];
			fputs(recent->path, file);
			if (recent->alias) {
				fputs("\t", file);
				fputs(recent->alias, file);
			}
			putc('\n', file);
		}
		fclose(file);
	}
}
static void addRecent(char* path, char* alias) {
	path += strlen(SDCARD_PATH); // makes paths platform agnostic
	int id = RecentArray_indexOf(recents, path);
	if (id==-1) { // add
		while (recents->count>=MAX_RECENTS) {
			Recent_free(Array_pop(recents));
		}
		Array_unshift(recents, Recent_new(path, alias));
	}
	else if (id>0) { // bump to top
		for (int i=id; i>0; i--) {
			void* tmp = recents->items[i-1];
			recents->items[i-1] = recents->items[i];
			recents->items[i] = tmp;
		}
	}
	saveRecents();
}

static int hasEmu(char* emu_name) {
	char pak_path[256];
	sprintf(pak_path, "%s/Emus/%s.pak/launch.sh", PAKS_PATH, emu_name);
	if (exists(pak_path)) return 1;

	sprintf(pak_path, "%s/Emus/%s/%s.pak/launch.sh", SDCARD_PATH, PLATFORM, emu_name);
	return exists(pak_path);
}
static int hasCue(char* dir_path, char* cue_path) { // NOTE: dir_path not rom_path
	char* tmp = strrchr(dir_path, '/') + 1; // folder name
	sprintf(cue_path, "%s/%s.cue", dir_path, tmp);
	return exists(cue_path);
}
static int hasM3u(char* rom_path, char* m3u_path) { // NOTE: rom_path not dir_path
	char* tmp;
	
	strcpy(m3u_path, rom_path);
	tmp = strrchr(m3u_path, '/') + 1;
	tmp[0] = '\0';
	
	// path to parent directory
	char base_path[256];
	strcpy(base_path, m3u_path);
	
	tmp = strrchr(m3u_path, '/');
	tmp[0] = '\0';
	
	// get parent directory name
	char dir_name[256];
	tmp = strrchr(m3u_path, '/');
	strcpy(dir_name, tmp);
	
	// dir_name is also our m3u file name
	tmp = m3u_path + strlen(m3u_path); 
	strcpy(tmp, dir_name);

	// add extension
	tmp = m3u_path + strlen(m3u_path);
	strcpy(tmp, ".m3u");
	
	return exists(m3u_path);
}

static int hasRecents(void) {
	LOG_info("hasRecents %s\n", RECENT_PATH);
	int has = 0;
	
	Array* parent_paths = Array_new();
	if (exists(CHANGE_DISC_PATH)) {
		char sd_path[256];
		getFile(CHANGE_DISC_PATH, sd_path, 256);
		if (exists(sd_path)) {
			char* disc_path = sd_path + strlen(SDCARD_PATH); // makes path platform agnostic
			Recent* recent = Recent_new(disc_path, NULL);
			if (recent->available) has += 1;
			Array_push(recents, recent);
		
			char parent_path[256];
			strcpy(parent_path, disc_path);
			char* tmp = strrchr(parent_path, '/') + 1;
			tmp[0] = '\0';
			Array_push(parent_paths, strdup(parent_path));
		}
		unlink(CHANGE_DISC_PATH);
	}
	
	FILE* file = fopen(RECENT_PATH, "r"); // newest at top
	if (file) {
		char line[256];
		while (fgets(line,256,file)!=NULL) {
			normalizeNewline(line);
			trimTrailingNewlines(line);
			if (strlen(line)==0) continue; // skip empty lines
			
			// LOG_info("line: %s\n", line);
			
			char* path = line;
			char* alias = NULL;
			char* tmp = strchr(line,'\t');
			if (tmp) {
				tmp[0] = '\0';
				alias = tmp+1;
			}
			
			char sd_path[256];
			sprintf(sd_path, "%s%s", SDCARD_PATH, path);
			if (exists(sd_path)) {
				if (recents->count<MAX_RECENTS) {
					// this logic replaces an existing disc from a multi-disc game with the last used
					char m3u_path[256];
					if (hasM3u(sd_path, m3u_path)) { // TODO: this might tank launch speed
						char parent_path[256];
						strcpy(parent_path, path);
						char* tmp = strrchr(parent_path, '/') + 1;
						tmp[0] = '\0';
						
						int found = 0;
						for (int i=0; i<parent_paths->count; i++) {
							char* path = parent_paths->items[i];
							if (prefixMatch(path, parent_path)) {
								found = 1;
								break;
							}
						}
						if (found) continue;
						
						Array_push(parent_paths, strdup(parent_path));
					}
					
					// LOG_info("path:%s alias:%s\n", path, alias);
					
					Recent* recent = Recent_new(path, alias);
					if (recent->available) has += 1;
					Array_push(recents, recent);
				}
			}
		}
		fclose(file);
	}
	
	saveRecents();
	
	StringArray_free(parent_paths);
	return has>0;
}
static int hasCollections(void) {
	int has = 0;
	if (!exists(COLLECTIONS_PATH)) return has;
	
	DIR *dh = opendir(COLLECTIONS_PATH);
	struct dirent *dp;
	while((dp = readdir(dh)) != NULL) {
		if (hide(dp->d_name)) continue;
		has = 1;
		break;
	}
	closedir(dh);
	return has;
}
static int hasRoms(char* dir_name) {
	int has = 0;
	char emu_name[256];
	char rom_path[256];

	getEmuName(dir_name, emu_name);
	
	// check for emu pak
	if (!hasEmu(emu_name)) return has;
	
	// check for at least one non-hidden file (we're going to assume it's a rom)
	sprintf(rom_path, "%s/%s/", ROMS_PATH, dir_name);
	DIR *dh = opendir(rom_path);
	if (dh!=NULL) {
		struct dirent *dp;
		while((dp = readdir(dh)) != NULL) {
			if (hide(dp->d_name)) continue;
			has = 1;
			break;
		}
		closedir(dh);
	}
	// if (!has) printf("No roms for %s!\n", dir_name);
	return has;
}
// lodor: record the most-recent LOCAL play (offline) so the Continue tile reflects a just-played
// game IMMEDIATELY — before its save ever uploads. Writes last-play.txt in the recent.txt format
// (<path>\t<game>\t<when>\t<device>). The tile then picks whichever of local/server is NEWER.
static void Lodor_recordLocalPlay(const char* rompath, const char* alias) {
	if (!rompath || !rompath[0]) return;
	char game[256];
	if (alias && alias[0]) {
		// FIX (Continue-nesting): the Continue tile's display name is decorated as
		// '> Continue - <game>'. Recording THAT as the alias makes it nest on every
		// launch-from-Continue. Strip any leading Continue decoration -> bare game name.
		const char* a = alias;
		const char* CONT = "\xE2\x96\xB6  Continue \xE2\x80\x94 ";
		size_t clen = strlen(CONT);
		while (strncmp(a, CONT, clen) == 0) a += clen;
		strncpy(game, a, sizeof(game)-1); game[sizeof(game)-1] = 0;
	}
	else {
		const char* b = strrchr(rompath, '/'); b = b ? b+1 : rompath;
		strncpy(game, b, sizeof(game)-1); game[sizeof(game)-1]='\0';
		char* dot = strrchr(game, '.'); if (dot) *dot='\0';
	}
	// Local wall-time stamp. NOTE: this is no longer compared against the server's UTC --recent stamp
	// (Lodor_continueChoice now prefers local last-play outright, because the device clock and server
	// clock are in incomparable frames). It's recorded for diagnostics / a future age-based compare.
	char when[32]; time_t t = time(NULL); struct tm* tmv = localtime(&t);
	if (tmv) strftime(when, sizeof(when), "%Y-%m-%d %H:%M", tmv); else strcpy(when, "1970-01-01 00:00");
	char lp[MAX_PATH];
	sprintf(lp, "%s/Tools/%s/Lodor.pak/last-play.txt", SDCARD_PATH, PLATFORM);
	FILE* f = fopen(lp, "w");
	if (f) { fprintf(f, "%s\t%s\t%s\tthis device\n", rompath, game, when); fclose(f); }
}
// lodor: read one "<path>\t<game>\t<when>\t..." file into path/game/when (caller-sized buffers).
static int Lodor_readRecentLine(const char* file, char* path, char* game, char* when) {
	path[0]=game[0]=when[0]='\0';
	FILE* f = fopen(file, "r"); if (!f) return 0;
	char line[1024]; int ok=0;
	if (fgets(line, sizeof(line), f)) {
		char* nl=strpbrk(line,"\r\n"); if(nl)*nl='\0';
		char* t1=strchr(line,'\t');
		if (t1){ *t1++='\0'; char* t2=strchr(t1,'\t'); if(t2){*t2++='\0'; char* t3=strchr(t2,'\t'); if(t3)*t3='\0';
			strncpy(when,t2,31); when[31]='\0'; } strncpy(path,line,MAX_PATH-1); path[MAX_PATH-1]='\0';
			strncpy(game,t1,255); game[255]='\0'; ok=1; }
	}
	fclose(f); return ok;
}
// lodor: every leading state marker the engine may bake into a ROM filename, mirroring
// engine/platform/marker.go (MarkerOnDevice "✓ ", MarkerCloud "✘ ", legacy "[v] "/"[^] ").
// Order = resolution PREFERENCE for Continue: on-device real file first, cloud stub next,
// then unmarked/legacy. Kept in sync with marker.go by hand (the launcher is CGO-free).
static const char* LODOR_MARKER_PREFS[] = { "\xE2\x9C\x93 ", "\xE2\x9C\x98 ", "", "[v] ", "[^] " };
#define LODOR_MARKER_PREF_COUNT 5
// strip any known leading marker from a basename, returning the canonical (server-matched) stem.
static const char* Lodor_stripMarker(const char* base) {
	static const char* all[] = { "\xE2\x9C\x93 ", "\xE2\x9C\x98 ", "[v] ", "[^] " };
	for (int i=0; i<4; i++) {
		size_t l = strlen(all[i]);
		if (strncmp(base, all[i], l)==0) return base + l;
	}
	return base;
}
// lodor: Continue-path resolution is marker-AGNOSTIC. The recorded last-play / recent path
// carries whatever leading marker the ROM had when it was last played; a later marker flip
// (✘ stub -> ✓ downloaded, or ✓ -> ✘ after a delete) RENAMES the on-disk file, so the exact
// recorded path can 404 even though the game is sitting right there under the other marker.
// Try the recorded path verbatim first (so a still-valid path is used as-is), then the same
// canonical basename under every other known marker (and unmarked) in preference order. On a
// hit, rewrite `path` in place to the existing variant and return 1; else return 0.
static int Lodor_resolveMarkedPath(char* path) {
	if (!path || !path[0]) return 0;
	if (exists(path)) return 1; // recorded path is still valid — use it unchanged
	char* slash = strrchr(path, '/');
	if (!slash) return 0;
	size_t dlen = (size_t)(slash - path);
	char dir[MAX_PATH];
	if (dlen >= sizeof(dir)) return 0;
	memcpy(dir, path, dlen); dir[dlen] = '\0';
	char canon[MAX_PATH];
	strncpy(canon, Lodor_stripMarker(slash+1), sizeof(canon)-1);
	canon[sizeof(canon)-1] = '\0';
	for (int i=0; i<LODOR_MARKER_PREF_COUNT; i++) {
		char cand[MAX_PATH];
		int n = snprintf(cand, sizeof(cand), "%s/%s%s", dir, LODOR_MARKER_PREFS[i], canon);
		if (n > 0 && n < (int)sizeof(cand) && exists(cand)) {
			strcpy(path, cand);
			return 1;
		}
	}
	return 0;
}
// lodor: the Continue target = the NEWER of the server's most-recent save (recent.txt) and the
// most-recent LOCAL play (last-play.txt), compared by <when> ("YYYY-MM-DD HH:MM" sorts lexically;
// ties favor local — you JUST played it). Returns 1 + fills path_out/game_out, else 0.
static int Lodor_continueChoice(char* path_out, char* game_out) {
	char base[MAX_PATH];
	char sp[MAX_PATH], sg[256], sw[32], lpp[MAX_PATH], lg[256], lw[32];
	sprintf(base, "%s/Tools/%s/Lodor.pak/recent.txt", SDCARD_PATH, PLATFORM);
	int haveS = Lodor_readRecentLine(base, sp, sg, sw);
	sprintf(base, "%s/Tools/%s/Lodor.pak/last-play.txt", SDCARD_PATH, PLATFORM);
	int haveL = Lodor_readRecentLine(base, lpp, lg, lw);
	const char *cp=NULL, *cg=NULL;
	(void)lw; (void)sw; // timestamps are NOT comparable across sources — see below
	// The device clock is local wall-time stored as UTC with no usable timezone, so the launcher's
	// last-play stamp and the engine's UTC --recent stamp are in DIFFERENT frames (~hours apart) and
	// CANNOT be compared — doing so let a stale server entry out-rank a game you'd just played here.
	// So on THIS device the LOCAL last-play wins whenever it exists: it's the one reliable record of
	// "what you last played on the thing in your hand." Server recent is the fallback for a fresh
	// device with no local history. (True cross-device newest-wins needs a frame-independent signal —
	// server-authoritative play-sessions or age-since-save — tracked as a follow-up.)
	if (haveL) { cp=lpp; cg=lg; }
	else if (haveS) { cp=sp; cg=sg; }
	if (!cp || !cp[0]) return 0;
	strncpy(path_out, cp, MAX_PATH-1); path_out[MAX_PATH-1]='\0';
	strncpy(game_out, cg, 255); game_out[255]='\0';
	return 1;
}
static Array* getRoot(void) {
	Array* root = Array_new();
	
	// lodor: pending saves are no longer a top-of-menu banner ROW — they're shown as a small clickable
	// "circle bug" badge inline above the LodorOS watermark (count = pending; RIGHT focuses it, A uploads).
	// See Lodor_drawBadge / Lodor_pendingCount and the badge-focus input intercept. Frees the top slot.

	Array* entries = Array_new();
	DIR* dh = opendir(ROMS_PATH);
	if (dh!=NULL) {
		struct dirent *dp;
		char* tmp;
		char full_path[256];
		sprintf(full_path, "%s/", ROMS_PATH);
		tmp = full_path + strlen(full_path);
		Array* emus = Array_new();
		while((dp = readdir(dh)) != NULL) {
			if (hide(dp->d_name)) continue;
			if (hasRoms(dp->d_name)) {
				strcpy(tmp, dp->d_name);
				Array_push(emus, Entry_new(full_path, ENTRY_DIR));
			}
		}
		EntryArray_sort(emus);
		Entry* prev_entry = NULL;
		for (int i=0; i<emus->count; i++) {
			Entry* entry = emus->items[i];
			if (prev_entry!=NULL) {
				if (exactMatch(prev_entry->name, entry->name)) {
					Entry_free(entry);
					continue;
				}
			}
			Array_push(entries, entry);
			prev_entry = entry;
		}
		Array_free(emus); // just free the array part, entries now owns emus entries
		closedir(dh);
	}
	
	// copied/modded from Directory_index
	// we don't support hidden remaps here
	char map_path[256];
	sprintf(map_path, "%s/map.txt", ROMS_PATH);
	if (entries->count>0 && exists(map_path)) {
		FILE* file = fopen(map_path, "r");
		if (file) {
			Hash* map = Hash_new();
			char line[256];
			while (fgets(line,256,file)!=NULL) {
				normalizeNewline(line);
				trimTrailingNewlines(line);
				if (strlen(line)==0) continue; // skip empty lines

				char* tmp = strchr(line,'\t');
				if (tmp) {
					tmp[0] = '\0';
					char* key = line;
					char* value = tmp+1;
					Hash_set(map, key, value);
				}
			}
			fclose(file);
			
			int resort = 0;
			for (int i=0; i<entries->count; i++) {
				Entry* entry = entries->items[i];
				char* filename = strrchr(entry->path, '/')+1;
				char* alias = Hash_get(map, filename);
				if (alias) {
					free(entry->name);
					entry->name = strdup(alias);
					resort = 1;
				}
			} 
			if (resort) EntryArray_sort(entries);
			Hash_free(map);
		}
	}
	
	if (hasCollections()) {
		if (entries->count) Array_push(root, Entry_new(COLLECTIONS_PATH, ENTRY_DIR));
		else { // no visible systems, promote collections to root
			dh = opendir(COLLECTIONS_PATH);
			if (dh!=NULL) {
				struct dirent *dp;
				char* tmp;
				char full_path[256];
				sprintf(full_path, "%s/", COLLECTIONS_PATH);
				tmp = full_path + strlen(full_path);
				Array* collections = Array_new();
				while((dp = readdir(dh)) != NULL) {
					if (hide(dp->d_name)) continue;
					strcpy(tmp, dp->d_name);
					Array_push(collections, Entry_new(full_path, ENTRY_DIR)); // yes, collections are fake directories
				}
				EntryArray_sort(collections);
				for (int i=0; i<collections->count; i++) {
					Array_push(entries, collections->items[i]);
				}
				Array_free(collections); // just free the array part, entries now owns collections entries
				closedir(dh);
			}
		}
	}
	
	// lodor: recents below Collections so RomM Collections sit at the TOP of the root menu
	if (hasRecents()) Array_push(root, Entry_new(FAUX_RECENT_PATH, ENTRY_DIR));

	// add systems to root
	for (int i=0; i<entries->count; i++) {
		Array_push(root, entries->items[i]);
	}
	Array_free(entries); // root now owns entries' entries
	
	// lodor TWO-MENU model: the ROOT front-door is the ROUTINE SYNC menu (Sync Now /
	// Refresh Library / Download BIOS / Sync Feed). It is labeled "Sync" — NOT "Lodor" —
	// so it reads as the routine-use sync menu, not a settings hub. The Lodor/RomM SETTINGS
	// menu lives under Tools (same pak path, routed to a different overlay by location).
	// The de-weld renamed this pak Sync.pak -> Lodor.pak; prefer the new name and fall
	// back to the legacy name so pre-de-weld cards still surface the front-door entry.
	char* hoardui_sync_pak = SDCARD_PATH "/Tools/" PLATFORM "/Lodor.pak";
	char* hoardui_sync_pak_legacy = SDCARD_PATH "/Tools/" PLATFORM "/Sync.pak";
	if (exists(hoardui_sync_pak) || exists(hoardui_sync_pak_legacy)) {
		Entry* lodor_sync_e = Entry_new(exists(hoardui_sync_pak) ? hoardui_sync_pak : hoardui_sync_pak_legacy, ENTRY_PAK);
		free(lodor_sync_e->name); lodor_sync_e->name = strdup("Sync"); // front-door label, not the pak's "Lodor"
		Array_push(root, lodor_sync_e);
	}
	char* tools_path = SDCARD_PATH "/Tools/" PLATFORM;
	if (exists(tools_path) && !simple_mode) Array_push(root, Entry_new(tools_path, ENTRY_DIR));

	// lodor: "Continue" hero row at index 0 — the most-recently-played game across ALL devices
	// (RomM server truth, cached to recent.txt by the sync sequence; falls back to the local
	// recents[0] when offline). recent.txt line: <localRomPath>\t<game>\t<when>\t<device>. We
	// Array_unshift so it lands at index 0; tapping rides the normal A-on-ROM path (a 0-byte cloud
	// stub downloads-then-launches; an on-device file launches). Guarded on the path existing, so a
	// stale entry (library changed) shows no tile rather than a dead row.
	{
		char lodor_cpath[MAX_PATH] = ""; char lodor_cgame[256] = "";
		Lodor_continueChoice(lodor_cpath, lodor_cgame); // newest of server recent.txt vs local last-play.txt
		// marker-agnostic: resolve to whichever marker variant (✓/✘/unmarked/legacy) is actually
		// on the card, so a post-play marker flip doesn't hide a game that's still present.
		if (lodor_cpath[0] && Lodor_resolveMarkedPath(lodor_cpath)) {
			Entry* lodor_ce = Entry_new(lodor_cpath, ENTRY_ROM);
			char lodor_ct[320];
			if (lodor_cgame[0]) snprintf(lodor_ct, sizeof(lodor_ct), "\xE2\x96\xB6  Continue \xE2\x80\x94 %s", lodor_cgame);
			else                snprintf(lodor_ct, sizeof(lodor_ct), "\xE2\x96\xB6  Continue");
			free(lodor_ce->name); lodor_ce->name = strdup(lodor_ct);
			Array_unshift(root, lodor_ce);
		}
	}

	return root;
}
static Array* getRecents(void) {
	Array* entries = Array_new();
	for (int i=0; i<recents->count; i++) {
		Recent* recent = recents->items[i];
		if (!recent->available) continue;
		
		char sd_path[256];
		sprintf(sd_path, "%s%s", SDCARD_PATH, recent->path);
		int type = suffixMatch(".pak", sd_path) ? ENTRY_PAK : ENTRY_ROM; // ???
		Entry* entry = Entry_new(sd_path, type);
		if (recent->alias) {
			free(entry->name);
			entry->name = strdup(recent->alias);
		}
		Array_push(entries, entry);
	}
	return entries;
}
static Array* getCollection(char* path) {
	Array* entries = Array_new();
	FILE* file = fopen(path, "r");
	if (file) {
		char line[256];
		while (fgets(line,256,file)!=NULL) {
			normalizeNewline(line);
			trimTrailingNewlines(line);
			if (strlen(line)==0) continue; // skip empty lines
			
			char sd_path[256];
			sprintf(sd_path, "%s%s", SDCARD_PATH, line);
			if (exists(sd_path)) {
				int type = suffixMatch(".pak", sd_path) ? ENTRY_PAK : ENTRY_ROM; // ???
				Array_push(entries, Entry_new(sd_path, type));
				
				// char emu_name[256];
				// getEmuName(sd_path, emu_name);
				// if (hasEmu(emu_name)) {
					// Array_push(entries, Entry_new(sd_path, ENTRY_ROM));
				// }
			}
		}
		fclose(file);
	}
	return entries;
}
static Array* getDiscs(char* path){
	
	// TODO: does path have SDCARD_PATH prefix?
	
	Array* entries = Array_new();
	
	char base_path[256];
	strcpy(base_path, path);
	char* tmp = strrchr(base_path, '/') + 1;
	tmp[0] = '\0';
	
	// TODO: limit number of discs supported (to 9?)
	FILE* file = fopen(path, "r");
	if (file) {
		char line[256];
		int disc = 0;
		while (fgets(line,256,file)!=NULL) {
			normalizeNewline(line);
			trimTrailingNewlines(line);
			if (strlen(line)==0) continue; // skip empty lines
			
			char disc_path[256];
			sprintf(disc_path, "%s%s", base_path, line);
						
			if (exists(disc_path)) {
				disc += 1;
				Entry* entry = Entry_new(disc_path, ENTRY_ROM);
				free(entry->name);
				char name[16];
				sprintf(name, "Disc %i", disc);
				entry->name = strdup(name);
				Array_push(entries, entry);
			}
		}
		fclose(file);
	}
	return entries;
}
static int getFirstDisc(char* m3u_path, char* disc_path) { // based on getDiscs() natch
	int found = 0;

	char base_path[256];
	strcpy(base_path, m3u_path);
	char* tmp = strrchr(base_path, '/') + 1;
	tmp[0] = '\0';
	
	FILE* file = fopen(m3u_path, "r");
	if (file) {
		char line[256];
		while (fgets(line,256,file)!=NULL) {
			normalizeNewline(line);
			trimTrailingNewlines(line);
			if (strlen(line)==0) continue; // skip empty lines
			
			sprintf(disc_path, "%s%s", base_path, line);
						
			if (exists(disc_path)) found = 1;
			break;
		}
		fclose(file);
	}
	return found;
}

// lodor: for an .m3u multi-disc playlist, report whether ANY referenced disc file is
// missing or a 0-byte stub. Disc lines are resolved relative to the m3u's directory
// (the engine writes "<Game>/<disc>" lines). A non-.m3u path, an unreadable/empty
// playlist, or a playlist whose every disc is present-and-nonzero returns 0 (nothing to
// fetch). This is the multi-disc analogue of the single-file 0-byte-stub check: a real
// 183-byte FFVII.m3u whose 3 CHDs never downloaded must NOT be handed to the emulator
// (that black-screens); it must route through the download-on-launch path first.
static int Lodor_m3uMissingDiscs(const char* path) {
	if (!path || !suffixMatch(".m3u", (char*)path)) return 0;

	char base_path[256];
	strncpy(base_path, path, sizeof(base_path)-1);
	base_path[sizeof(base_path)-1] = '\0';
	char* slash = strrchr(base_path, '/');
	if (!slash) return 0;
	slash[1] = '\0'; // keep the trailing '/'

	FILE* file = fopen(path, "r");
	if (!file) return 0;
	int missing = 0, listed = 0;
	char line[256];
	while (fgets(line, sizeof(line), file) != NULL) {
		normalizeNewline(line);
		trimTrailingNewlines(line);
		if (strlen(line)==0) continue; // skip empty lines
		listed += 1;
		char disc_path[512];
		snprintf(disc_path, sizeof(disc_path), "%s%s", base_path, line);
		struct stat st;
		if (stat(disc_path, &st)!=0 || st.st_size==0) { missing = 1; break; }
	}
	fclose(file);
	// A playlist that lists NO discs is itself broken -> treat as needing a fetch so the
	// engine re-materializes it, rather than launching an empty set.
	if (listed==0) return 1;
	return missing;
}

// lodor: unified "this ROM isn't fully on the card yet" test for the launch gate.
// True for a 0-byte single-file cloud stub OR a real multi-disc .m3u whose discs are
// missing/stub. Both route into Lodor_downloadThenLaunch (engine --download resolves the
// rom id from the path and fetches the single file or ALL discs + rewrites the .m3u).
static int Lodor_needsFetch(const char* path) {
	if (!path) return 0;
	struct stat st;
	if (stat(path, &st)==0 && st.st_size==0) return 1; // 0-byte single-file stub
	return Lodor_m3uMissingDiscs(path);                // real .m3u, discs absent/stub
}

static void addEntries(Array* entries, char* path) {
	DIR *dh = opendir(path);
	if (dh!=NULL) {
		struct dirent *dp;
		char* tmp;
		char full_path[256];
		sprintf(full_path, "%s/", path);
		tmp = full_path + strlen(full_path);
		while((dp = readdir(dh)) != NULL) {
			if (hide(dp->d_name)) continue;
			strcpy(tmp, dp->d_name);
			int is_dir = dp->d_type==DT_DIR;
			int type;
			if (is_dir) {
				// TODO: this should make sure launch.sh exists
				if (suffixMatch(".pak", dp->d_name)) {
					type = ENTRY_PAK;
				}
				else {
					type = ENTRY_DIR;
				}
			}
			else {
				if (prefixMatch(COLLECTIONS_PATH, full_path)) {
					type = ENTRY_DIR; // :shrug:
				}
				else {
					type = ENTRY_ROM;
				}
			}
			Array_push(entries, Entry_new(full_path, type));
		}
		closedir(dh);
	}
}

static int isConsoleDir(char* path) {
	char* tmp;
	char parent_dir[256];
	strcpy(parent_dir, path);
	tmp = strrchr(parent_dir, '/');
	tmp[0] = '\0';
	
	return exactMatch(parent_dir, ROMS_PATH);
}

static Array* getEntries(char* path){
	Array* entries = Array_new();

	if (isConsoleDir(path)) { // top-level console folder, might collate
		char collated_path[256];
		strcpy(collated_path, path);
		char* tmp = strrchr(collated_path, '(');
		// 1 because we want to keep the opening parenthesis to avoid collating "Game Boy Color" and "Game Boy Advance" into "Game Boy"
		// but conditional so we can continue to support a bare tag name as a folder name
		if (tmp) tmp[1] = '\0'; 
		
		DIR *dh = opendir(ROMS_PATH);
		if (dh!=NULL) {
			struct dirent *dp;
			char full_path[256];
			sprintf(full_path, "%s/", ROMS_PATH);
			tmp = full_path + strlen(full_path);
			// while loop so we can collate paths, see above
			while((dp = readdir(dh)) != NULL) {
				if (hide(dp->d_name)) continue;
				if (dp->d_type!=DT_DIR) continue;
				strcpy(tmp, dp->d_name);
			
				if (!prefixMatch(collated_path, full_path)) continue;
				addEntries(entries, full_path);
			}
			closedir(dh);
		}
	}
	else addEntries(entries, path); // just a subfolder

	// lodor FIX 1: hide() (common/utils.c) filters Lodor.pak/Sync.pak out of EVERY
	// directory listing, so the engine pak never shows up as a launchable row in Tools.
	// But the SETTINGS overlay is reached precisely by opening Lodor.pak from *inside*
	// Tools — the BTN_A handler routes by location (root -> Sync front-door, deeper ->
	// Settings). Re-inject the entry for the Tools/<platform> dir only, so the
	// front-door (root, named "Sync") and the settings entry (Tools, "Lodor Settings")
	// both exist, backed by one pak path; the existing location-based routing is intact.
	if (exactMatch(path, SDCARD_PATH "/Tools/" PLATFORM)) {
		char* lodor_settings_pak = SDCARD_PATH "/Tools/" PLATFORM "/Lodor.pak";
		char* lodor_settings_pak_legacy = SDCARD_PATH "/Tools/" PLATFORM "/Sync.pak";
		char* use = exists(lodor_settings_pak) ? lodor_settings_pak
		          : (exists(lodor_settings_pak_legacy) ? lodor_settings_pak_legacy : NULL);
		if (use) {
			Entry* settings_e = Entry_new(use, ENTRY_PAK);
			free(settings_e->name); settings_e->name = strdup("Lodor Settings");
			Array_push(entries, settings_e);
		}
	}

	EntryArray_sort(entries);
	return entries;
}

///////////////////////////////////////

static void queueNext(char* cmd) {
	LOG_info("cmd: %s\n", cmd);
	putFile("/tmp/next", cmd);
	quit = 1;
}

// §override (#144/#163) SECURITY: the launch fields (emu_name/emu_path/sd_path/core=) flow
// from on-card, garble-influenceable data (ROM paths + the .emu.txt sidecar). The legacy
// in-place '→'\'' expansion (a recursive replaceString) had NO destination bound and smashed the
// ≤256B stack buffers it escaped through. escapeSingleQuotes now writes into a SEPARATE,
// capacity-checked output buffer — the source is never mutated and can never overrun. Callers
// size the destination at 4*strlen(src)+1 (the exact worst case: every byte a quote) and read the
// returned dst. The old replaceString is gone; nothing else in the launcher used it.

// worst-case escaped size of a ≤255B field (every byte a ' → 4B) plus NUL; the launch fields
// (emu_name/emu_path/sd_path/core=) are all char[256] sources, so 1024 always suffices.
#define LODOR_ESC_MAX 1024

// escape src for single-quoted shell context into a caller-owned dst. Every ' becomes '\''.
// dst must be >= 4*strlen(src)+1. Returns dst, or NULL (and empties dst) when dst is too small
// — the caller MUST treat NULL as "refuse to launch" rather than run an unescaped command.
static char* escapeSingleQuotes(char* dst, size_t dstcap, const char* src) {
	if (!dst || dstcap == 0) return NULL;
	size_t di = 0;
	for (const char* s = src; *s; s++) {
		if (*s == '\'') {
			if (di + 4 >= dstcap) { dst[0] = '\0'; return NULL; } // need "'\\''" + NUL
			dst[di++] = '\'';
			dst[di++] = '\\';
			dst[di++] = '\'';
			dst[di++] = '\'';
		} else {
			if (di + 1 >= dstcap) { dst[0] = '\0'; return NULL; } // room for byte + NUL
			dst[di++] = *s;
		}
	}
	dst[di] = '\0';
	return dst;
}

// §atomic (#161) FAT32-safe whole-file write: write to "<path>.tmp", fflush + fsync the DATA to
// the card, close, then rename() over the target (atomic on FAT32) and fsync the directory so the
// rename itself is durable. A mid-write power-yank leaves either the OLD file intact or the fully
// -written new one — never a zeroed/torn file. Used for the load-bearing card writes (the active
// profile, the .emu sidecar, settings.conf). Returns 1 on success, 0 on any failure (caller keeps
// the old file; a failed write never corrupts). On failure the temp is removed.
static int Lodor_atomicWrite(const char* path, const char* content, size_t len) {
	char tmp[MAX_PATH];
	int n = snprintf(tmp, sizeof(tmp), "%s.tmp", path);
	if (n < 0 || (size_t)n >= sizeof(tmp)) return 0;
	FILE* f = fopen(tmp, "w");
	if (!f) return 0;
	int ok = (fwrite(content, 1, len, f) == len);
	if (ok) ok = (fflush(f) == 0);
	if (ok) ok = (fsync(fileno(f)) == 0); // force DATA to the card before the rename
	if (fclose(f) != 0) ok = 0;
	if (!ok) { unlink(tmp); return 0; }
	if (rename(tmp, path) != 0) { unlink(tmp); return 0; } // atomic swap over the live file
	// fsync the containing directory so the rename (the metadata) is itself durable
	char dir[MAX_PATH];
	strncpy(dir, path, sizeof(dir)-1); dir[sizeof(dir)-1] = '\0';
	char* slash = strrchr(dir, '/');
	if (slash) {
		*slash = '\0';
		int dfd = open(dir[0] ? dir : "/", O_RDONLY | O_DIRECTORY);
		if (dfd >= 0) { fsync(dfd); close(dfd); }
	}
	return 1;
}

///////////////////////////////////////

static void readyResumePath(char* rom_path, int type) {
	char* tmp;
	can_resume = 0;
	char path[256];
	strcpy(path, rom_path);
	
	if (!prefixMatch(ROMS_PATH, path)) return;
	
	char auto_path[256];
	if (type==ENTRY_DIR) {
		if (!hasCue(path, auto_path)) { // no cue?
			tmp = strrchr(auto_path, '.') + 1; // extension
			strcpy(tmp, "m3u"); // replace with m3u
			if (!exists(auto_path)) return; // no m3u
		}
		strcpy(path, auto_path); // cue or m3u if one exists
	}
	
	if (!suffixMatch(".m3u", path)) {
		char m3u_path[256];
		if (hasM3u(path, m3u_path)) {
			// change path to m3u path
			strcpy(path, m3u_path);
		}
	}
	
	char emu_name[256];
	Lodor_romTag(path, emu_name); // §override (#144): resume state stays keyed by FOLDER tag

	char rom_file[256];
	tmp = strrchr(path, '/') + 1;
	strcpy(rom_file, tmp);

	sprintf(slot_path, "%s/.minui/%s/%s.txt", SHARED_USERDATA_PATH, emu_name, rom_file); // /.userdata/.minui/<EMU>/<romname>.ext.txt
	
	can_resume = exists(slot_path);
}
static void readyResume(Entry* entry) {
	readyResumePath(entry->path, entry->type);
}

static void saveLast(char* path);
static void loadLast(void);

static int autoResume(void) {
	// NOTE: bypasses recents

	if (!exists(AUTO_RESUME_PATH)) return 0;
	
	char path[256];
	getFile(AUTO_RESUME_PATH, path, 256);
	unlink(AUTO_RESUME_PATH);
	sync();
	
	// make sure rom still exists
	char sd_path[256];
	sprintf(sd_path, "%s%s", SDCARD_PATH, path);
	if (!exists(sd_path)) return 0;
	
	// make sure emu still exists
	char emu_name[256];
	Lodor_romTag(sd_path, emu_name); // §override (#144)

	char emu_path[256];
	Lodor_resolveEmu(sd_path, emu_path); // §override (#144): sidecar-aware

	if (!exists(emu_path)) return 0;

	// putFile(LAST_PATH, FAUX_RECENT_PATH); // saveLast() will crash here because top is NULL

	// §override (#144): LODOR_ROM_TAG rides the /tmp/next eval (assignment-prefix) so the
	// pak's launch.sh keys saves/states by the FOLDER tag even when a variant pak runs;
	// LODOR_CORE_OVERRIDE (core= sidecar line) swaps the minarch core stem.
	// §override (#144/#163): escape each field into its own bounded buffer (worst case
	// 4*255+1) and snprintf with a truncation check — a garbled tag/path/core can no longer
	// overflow cmd[] or the escape targets, and a would-be-truncated command is refused.
	char cmd[1024];
	char emu_q[LODOR_ESC_MAX], path_q[LODOR_ESC_MAX];
	if (!escapeSingleQuotes(emu_q, sizeof(emu_q), emu_name) ||
	    !escapeSingleQuotes(path_q, sizeof(path_q), emu_path)) { LOG_error("autoResume: field too long to escape, refusing launch\n"); return 0; }
	char sd_q[LODOR_ESC_MAX];
	if (!escapeSingleQuotes(sd_q, sizeof(sd_q), sd_path)) { LOG_error("autoResume: rom path too long to escape, refusing launch\n"); return 0; }
	int n;
	if (lodor_core_override[0]) {
		char core_q[LODOR_ESC_MAX];
		if (!escapeSingleQuotes(core_q, sizeof(core_q), lodor_core_override)) { LOG_error("autoResume: core override too long to escape, refusing launch\n"); return 0; }
		n = snprintf(cmd, sizeof(cmd), "LODOR_ROM_TAG='%s' LODOR_CORE_OVERRIDE='%s' '%s' '%s'",
			emu_q, core_q, path_q, sd_q);
	}
	else {
		n = snprintf(cmd, sizeof(cmd), "LODOR_ROM_TAG='%s' '%s' '%s'", emu_q, path_q, sd_q);
	}
	if (n < 0 || (size_t)n >= sizeof(cmd)) { LOG_error("autoResume: launch command truncated, refusing launch\n"); return 0; }
	putInt(RESUME_SLOT_PATH, AUTO_RESUME_SLOT);
	queueNext(cmd);
	return 1;
}

static void openPak(char* path) {
	// NOTE: escapeSingleQuotes() modifies the passed string 
	// so we need to save the path before we call that
	if (prefixMatch(ROMS_PATH, path)) {
		addRecent(path, NULL);
	}
	saveLast(path);
	
	char path_q[LODOR_ESC_MAX];
	if (!escapeSingleQuotes(path_q, sizeof(path_q), path)) { LOG_error("openPak: path too long to escape, refusing launch\n"); return; }
	char cmd[LODOR_ESC_MAX + 32];
	int n = snprintf(cmd, sizeof(cmd), "'%s/launch.sh'", path_q);
	if (n < 0 || (size_t)n >= sizeof(cmd)) { LOG_error("openPak: launch command truncated, refusing launch\n"); return; }
	queueNext(cmd);
}
static void openRom(char* path, char* last) {
	LOG_info("openRom(%s,%s)\n", path, last);
	
	char sd_path[256];
	strcpy(sd_path, path);
	
	char m3u_path[256];
	int has_m3u = hasM3u(sd_path, m3u_path);
	
	char recent_path[256];
	strcpy(recent_path, has_m3u ? m3u_path : sd_path);
	
	if (has_m3u && suffixMatch(".m3u", sd_path)) {
		getFirstDisc(m3u_path, sd_path);
	}

	char emu_name[256];
	Lodor_romTag(sd_path, emu_name); // §override (#144): .minui bookkeeping keyed by FOLDER tag

	if (should_resume) {
		char slot[16];
		getFile(slot_path, slot, 16);
		putFile(RESUME_SLOT_PATH, slot);
		should_resume = 0;

		if (has_m3u) {
			char rom_file[256];
			strcpy(rom_file, strrchr(m3u_path, '/') + 1);
			
			// get disc for state
			char disc_path_path[256];
			sprintf(disc_path_path, "%s/.minui/%s/%s.%s.txt", SHARED_USERDATA_PATH, emu_name, rom_file, slot); // /.userdata/arm-480/.minui/<EMU>/<romname>.ext.0.txt

			if (exists(disc_path_path)) {
				// switch to disc path
				char disc_path[256];
				getFile(disc_path_path, disc_path, 256);
				if (disc_path[0]=='/') strcpy(sd_path, disc_path); // absolute
				else { // relative
					strcpy(sd_path, m3u_path);
					char* tmp = strrchr(sd_path, '/') + 1;
					strcpy(tmp, disc_path);
				}
			}
		}
	}
	else putInt(RESUME_SLOT_PATH,8); // resume hidden default state

	char emu_path[256];
	Lodor_resolveEmu(sd_path, emu_path); // §override (#144): sidecar-aware pak resolution

	// NOTE: escapeSingleQuotes() modifies the passed string
	// so we need to save the path before we call that
	addRecent(recent_path, recent_alias); // yiiikes
	Lodor_recordLocalPlay(recent_path, recent_alias); // Continue reflects this play immediately (offline)
	saveLast(last==NULL ? sd_path : last);

	// §override (#144): export LODOR_ROM_TAG (always — save-path integrity: Saves/<folder TAG>)
	// and LODOR_CORE_OVERRIDE (only when the sidecar names a core). /tmp/next is eval'd by the
	// MinUI.pak loop, so the POSIX assignment-prefix scopes both to this launch only.
	// §override (#144/#163): bounded escape + truncation-checked snprintf (see autoResume).
	char cmd[1024];
	char emu_q[LODOR_ESC_MAX], path_q[LODOR_ESC_MAX], sd_q[LODOR_ESC_MAX];
	if (!escapeSingleQuotes(emu_q, sizeof(emu_q), emu_name) ||
	    !escapeSingleQuotes(path_q, sizeof(path_q), emu_path) ||
	    !escapeSingleQuotes(sd_q, sizeof(sd_q), sd_path)) { LOG_error("openRom: field too long to escape, refusing launch\n"); return; }
	int n;
	if (lodor_core_override[0]) {
		char core_q[LODOR_ESC_MAX];
		if (!escapeSingleQuotes(core_q, sizeof(core_q), lodor_core_override)) { LOG_error("openRom: core override too long to escape, refusing launch\n"); return; }
		n = snprintf(cmd, sizeof(cmd), "LODOR_ROM_TAG='%s' LODOR_CORE_OVERRIDE='%s' '%s' '%s'",
			emu_q, core_q, path_q, sd_q);
	}
	else {
		n = snprintf(cmd, sizeof(cmd), "LODOR_ROM_TAG='%s' '%s' '%s'", emu_q, path_q, sd_q);
	}
	if (n < 0 || (size_t)n >= sizeof(cmd)) { LOG_error("openRom: launch command truncated, refusing launch\n"); return; }
	queueNext(cmd);
}
static void openDirectory(char* path, int auto_launch) {
	char auto_path[256];
	if (hasCue(path, auto_path) && auto_launch) {
		openRom(auto_path, path);
		return;
	}

	char m3u_path[256];
	strcpy(m3u_path, auto_path);
	char* tmp = strrchr(m3u_path, '.') + 1; // extension
	strcpy(tmp, "m3u"); // replace with m3u
	if (exists(m3u_path) && auto_launch) {
		auto_path[0] = '\0';
		if (getFirstDisc(m3u_path, auto_path)) {
			openRom(auto_path, path);
			return;
		}
		// TODO: doesn't handle empty m3u files
	}
	
	int selected = 0;
	int start = selected;
	int end = 0;
	if (top && top->entries->count>0) {
		if (restore_depth==stack->count && top->selected==restore_relative) {
			selected = restore_selected;
			start = restore_start;
			end = restore_end;
		}
	}
	
	top = Directory_new(path, selected);
	top->start = start;
	top->end = end ? end : ((top->entries->count<MAIN_ROW_COUNT) ? top->entries->count : MAIN_ROW_COUNT);

	Array_push(stack, top);
}
static void closeDirectory(void) {
	restore_selected = top->selected;
	restore_start = top->start;
	restore_end = top->end;
	DirectoryArray_pop(stack);
	restore_depth = stack->count;
	top = stack->items[stack->count-1];
	restore_relative = top->selected;
}

// lodor FIX 3 (#104): re-scan the CURRENT top directory in place (same path), replacing its
// entry list so filesystem changes made out-of-band — e.g. new Roms/<System (TAG)> folders
// created by a Refresh Library "--mirror-catalog" run — appear WITHOUT a reboot. Preserves the
// current selection/scroll window where the new list still has room. Used right after a Refresh.
static void Lodor_rescanTop(void) {
	if (!top || stack->count<1) return;
	char path[MAX_PATH];
	strncpy(path, top->path, sizeof(path)-1); path[sizeof(path)-1]='\0';
	int sel = top->selected;
	Directory* fresh = Directory_new(path, sel);
	int count = fresh->entries ? fresh->entries->count : 0;
	if (fresh->selected >= count) fresh->selected = count>0 ? count-1 : 0;
	if (fresh->selected < 0) fresh->selected = 0;
	fresh->start = 0;
	fresh->end = (count<MAIN_ROW_COUNT) ? count : MAIN_ROW_COUNT;
	if (fresh->selected >= fresh->end) {
		fresh->end = fresh->selected + 1;
		fresh->start = fresh->end - MAIN_ROW_COUNT;
		if (fresh->start < 0) fresh->start = 0;
		fresh->end = (fresh->start + MAIN_ROW_COUNT < count) ? fresh->start + MAIN_ROW_COUNT : count;
	}
	DirectoryArray_pop(stack);     // free the stale top
	Array_push(stack, fresh);
	top = fresh;
}

static void Entry_open(Entry* self) {
	recent_alias = self->name;  // yiiikes
	if (self->type==ENTRY_ROM) {
		char *last = NULL;
		if (prefixMatch(COLLECTIONS_PATH, top->path)) {
			char* tmp;
			char filename[256];
			
			tmp = strrchr(self->path, '/');
			if (tmp) strcpy(filename, tmp+1);
			
			char last_path[256];
			sprintf(last_path, "%s/%s", top->path, filename);
			last = last_path;
		}
		openRom(self->path, last);
	}
	else if (self->type==ENTRY_PAK) {
		openPak(self->path);
	}
	else if (self->type==ENTRY_DIR) {
		openDirectory(self->path, 1);
	}
}

///////////////////////////////////////

static void saveLast(char* path) {
	// special case for recently played
	if (exactMatch(top->path, FAUX_RECENT_PATH)) {
		// NOTE: that we don't have to save the file because
		// your most recently played game will always be at
		// the top which is also the default selection
		path = FAUX_RECENT_PATH;
	}
	putFile(LAST_PATH, path);
}
static void loadLast(void) { // call after loading root directory
	if (!exists(LAST_PATH)) return;

	char last_path[256];
	getFile(LAST_PATH, last_path, 256);
	
	char full_path[256];
	strcpy(full_path, last_path);
	
	char* tmp;
	char filename[256];
	tmp = strrchr(last_path, '/');
	if (tmp) strcpy(filename, tmp);
	
	Array* last = Array_new();
	while (!exactMatch(last_path, SDCARD_PATH)) {
		Array_push(last, strdup(last_path));
		
		char* slash = strrchr(last_path, '/');
		last_path[(slash-last_path)] = '\0';
	}
	
	while (last->count>0) {
		char* path = Array_pop(last);
		if (!exactMatch(path, ROMS_PATH)) { // romsDir is effectively root as far as restoring state after a game
			char collated_path[256];
			collated_path[0] = '\0';
			if (suffixMatch(")", path) && isConsoleDir(path)) {
				strcpy(collated_path, path);
				tmp = strrchr(collated_path, '(');
				if (tmp) tmp[1] = '\0'; // 1 because we want to keep the opening parenthesis to avoid collating "Game Boy Color" and "Game Boy Advance" into "Game Boy"
			}
			
			for (int i=0; i<top->entries->count; i++) {
				Entry* entry = top->entries->items[i];
			
				// NOTE: strlen() is required for collated_path, '\0' wasn't reading as NULL for some reason
				if (exactMatch(entry->path, path) || (strlen(collated_path) && prefixMatch(collated_path, entry->path)) || (prefixMatch(COLLECTIONS_PATH, full_path) && suffixMatch(filename, entry->path))) {
					top->selected = i;
					if (i>=top->end) {
						top->start = i;
						top->end = top->start + MAIN_ROW_COUNT;
						if (top->end>top->entries->count) {
							top->end = top->entries->count;
							top->start = top->end - MAIN_ROW_COUNT;
						}
					}
					if (last->count==0 && !exactMatch(entry->path, FAUX_RECENT_PATH) && !(!exactMatch(entry->path, COLLECTIONS_PATH) && prefixMatch(COLLECTIONS_PATH, entry->path))) break; // don't show contents of auto-launch dirs
				
					if (entry->type==ENTRY_DIR) {
						openDirectory(entry->path, 0);
						break;
					}
				}
			}
		}
		free(path); // we took ownership when we popped it
	}
	
	StringArray_free(last);
}

///////////////////////////////////////

static void Menu_init(void) {
	stack = Array_new(); // array of open Directories
	recents = Array_new();

	openDirectory(SDCARD_PATH, 0);
	loadLast(); // restore state when available
}
static void Menu_quit(void) {
	RecentArray_free(recents);
	DirectoryArray_free(stack);
}

///////////////////////////////////////
// lodor: native per-game action menu (replaces the old external Options pak).
// Mirrors MinUI's show_version modal pattern: dedicated state flags, separate input handling
// that blocks the main menu, a separate render path, and GFX_/PAD_ primitives only — no new
// rendering engine. All Arrays here hold Entry* (name = display label, path = an id string).

#define LODOR_ROMM_BIN "/Tools/" PLATFORM "/Lodor.pak/bin/romm-run"
// lodor §tailscale: the QR-onboarding shell entrypoint (sources romm-sync-lib.sh +
// tailscale-lib.sh). Subcommands: `up` (interactive tailscaled bring-up; prints
// RESULT ts_url=<login URL>), `status` (RESULT ts_state=connected|pending|stopped),
// `mark-tier1 <host>` (adds socks5_proxy+tier to hosts[0]), `down`.
#define LODOR_TS_BIN "/Tools/" PLATFORM "/Lodor.pak/bin/romm-tailscale"
// lodor §tailscale: probe for the bundled userspace daemon — the capability gate keys
// off this (absent on the 128MB miyoomini, and on any build that didn't ship the binary).
#define LODOR_TS_DAEMON "/Tools/" PLATFORM "/Lodor.pak/tailscale/tailscaled"
#define LODOR_QUEUE_FILE SDCARD_PATH "/Tools/" PLATFORM "/Lodor.pak/download-queue.txt"
// The engine reads/writes config.json CWD-relative, and romm-run runs the binary
// with cwd = the Lodor pak — so the canonical config lives here. The boot-gate reads
// it directly (engine-free) to decide library-vs-onboarding; the wizard never writes it
// (the engine owns it via romm-run --set-server / --pair / --register-device).
#define LODOR_CONFIG_FILE SDCARD_PATH "/Tools/" PLATFORM "/Lodor.pak/config.json"

static int    lodor_show_actions = 0;   // action menu open
static uint32_t lodor_keepawake_until = 0; // SDL_GetTicks() deadline: hold autosleep off until then (post-task grace)
static int    lodor_badge_focused = 0;  // 1 = the side pending-saves badge has focus (press RIGHT at root)
static long   lodor_synced_shown_ts = 0; // ts of the "synced ✓" flash currently drawn (0 = none); acked on next input
// lodor §toast: transient status messages drawn as a pill over the UI, non-blocking.
// Product rule (no-fake-ui-state): a toast is only ever emitted from an observed fact —
// e.g. the OFFLINE variant fires when pending-saves.txt actually grew while PLAT_isOnline()
// reports no connectivity. Nothing here invents forward progress. Design: a fixed ring of
// 4 slots; toasts show ONE at a time, oldest first, and each one's on-screen clock starts
// only when it reaches the front, so a queued toast never expires unseen. When the ring is
// full the oldest entry is overwritten (fresh news wins).
#define LODOR_TOAST_CAP 4
enum { LODOR_TOAST_INFO=0, LODOR_TOAST_OK, LODOR_TOAST_OFFLINE, LODOR_TOAST_FAIL };
typedef struct {
	char text[128];
	int  kind;             // LODOR_TOAST_* — drives pill color + on-screen time
	unsigned int show_ms;  // how long this toast stays up once it reaches the front
	unsigned int shown_at; // SDL_GetTicks() when it became the front toast (0 = still queued)
} LodorToast;
static LodorToast lodor_toast_ring[LODOR_TOAST_CAP];
static int    lodor_toast_head = 0;       // ring index of the front (visible) toast
static int    lodor_toast_len  = 0;       // occupied slots
static int    lodor_toast_was_active = 0; // forces one clearing repaint after the last toast expires
static int    lodor_prev_pending = -1;    // last-seen pending count at root (-1 = unknown/first visit)
static int    lodor_action_sel   = 0;
static Array* lodor_action_items = NULL; // Entry*: name=label, path=action-id
static int    lodor_actions_from_search = 0; // 1 = action menu was opened from a search result

static int    lodor_show_saves   = 0;   // server-saves sub-list open
static int    lodor_saves_sel    = 0;
static Array* lodor_saves_items  = NULL; // Entry*: name=human label, path=save_id

static int    lodor_show_confirm = 0;   // confirm modal open
static int    lodor_confirm_kind = 0;   // 1=delete, 2=restore
static int    lodor_confirm_stuck = 0;  // count for kind==3 (dismiss pending reminder)
static int    lodor_show_details = 0;   // details info modal open
// §override (#144): the per-game Emulator picker (overlays the actions modal, same chrome)
static int    lodor_show_emupick = 0;   // emulator picker open
static int    lodor_emupick_sel  = 0;
static Array* lodor_emupick_items = NULL; // Entry*: name=row label, path=PAKNAME ("" = default)
// lodor §gameswitch (#149): the Game Switcher overlay — full-screen preview of the last
// 8 recents (X in the browse view). A SEPARATE overlay: NO main-menu changes (the old
// carousel redesign was reverted in 30596d1 and must not creep back).
#define LODOR_SWITCH_MAX 8
static int  lodor_show_switch  = 0;
static int  lodor_switch_sel   = 0;
static int  lodor_switch_count = 0;
static char lodor_switch_path[LODOR_SWITCH_MAX][MAX_PATH]; // sd_path of the recent
static char lodor_switch_name[LODOR_SWITCH_MAX][256];      // display name
static char lodor_switch_shot[LODOR_SWITCH_MAX][MAX_PATH]; // newest preview image ("" = none)
static char lodor_switch_cap[LODOR_SWITCH_MAX][96];        // playtime caption ("" = none)

// context for the currently-open menus
static char   lodor_rompath[MAX_PATH];  // absolute path of the selected ROM
static char   lodor_gamename[256];      // display name (untrimmed entry->name)
static int    lodor_on_device = 0;      // 1 = real file on card, 0 = 0-byte cloud stub
static long   lodor_filesize = 0;       // bytes
static char   lodor_confirm_saveid[64]; // save_id pending a restore confirm
static char   lodor_confirm_savedev[96]; // device label for the restore-confirmation message
static char   lodor_confirm_savewhen[64]; // relative-age (or date) of the chosen Flashback point

// lodor: native Sync front-door overlay (replaces grout32 --sync-menu) and the
// pending-banner / download-on-launch flows. All reuse Lodor_drawList + the modal chains.
static int    lodor_show_sync = 0;   // Sync front-door menu open (ROOT) — ROUTINE sync only
static int    lodor_sync_sel  = 0;
static int    lodor_wifi_warm = 0;   // cached KEEP_WIFI_WARM for the toggle label
static int    lodor_quality_dots = 0; // cached SHOW_QUALITY_DOTS (opt-in per-system quality dots)
// lodor MULTI-USER: cached badge toggle + the active profile's label/initial. lodor_profile_label
// is "" on a single-user card (no profiles) -> no badge, no switcher entry change.
static int    lodor_user_badge   = 1;   // cached SHOW_USER_BADGE (default ON)
static int    lodor_box_art      = 1;   // cached fetch_covers (#96 box art; default ON)
// FIX 3 (#99): the background cover-fetch feature (upper-right "Covers N/M" pill + the
// "Refresh box art (background)" Sync action) is gated OFF on the weakest tier — the 128MB
// miyoomini — where a detached cover warmer + a per-frame status poll aren't worth the RAM.
// PLATFORM is a string literal macro, so this is a one-shot runtime strcmp, set in main().
static int    lodor_bg_covers_ok = 0;   // 1 when this platform may run the bg cover-fetch feature
static char   lodor_profile_label[64] = ""; // active profile label ("" = single-user)
// MULTI-USER profile switcher overlay (Tools -> Lodor Settings -> Switch Profile).
static int    lodor_show_profiles = 0;  // profile switcher list open
static int    lodor_profiles_sel  = 0;
static Array* lodor_profile_items = NULL; // Entry*: name=label (or "Add Profile"), path=label
static int    lodor_ob_add_profile = 0; // 1 = onboarding running as LIGHT Add-Profile (pair+name only)

// lodor FEATURE 1 (Smart Delete on-ramp): SD card free/used space, shown in the Sync menu
// header. Computed ONCE on menu open (Lodor_computeStorage) — cheap, never per-frame. statvfs
// on SDCARD_PATH (the card root where Roms live): free = f_bavail*f_frsize, total =
// f_blocks*f_frsize. lodor_storage_str is rendered right-aligned on the Sync title row by
// Lodor_drawList when lodor_storage_active is set. Display-only: no eviction yet.
static char lodor_storage_str[48] = ""; // e.g. "12.4G free / 64G" ("" = unknown/hidden)
static int  lodor_storage_active = 0;   // 1 = draw lodor_storage_str on the Lodor_drawList title row

// Human-readable size: tenths of a GB above 1G, whole MB below. Pure integer math (no float
// printf dependency surprises across the toolchains); ASCII only.
static void Lodor_fmtBytes(unsigned long long b, char* out, int cap) {
	const unsigned long long GB = 1024ULL*1024ULL*1024ULL;
	const unsigned long long MB = 1024ULL*1024ULL;
	if (b >= GB) {
		unsigned long long tenths = (b * 10ULL) / GB; // e.g. 124 -> 12.4G
		snprintf(out, cap, "%llu.%lluG", tenths/10ULL, tenths%10ULL);
	} else {
		snprintf(out, cap, "%lluM", b / MB);
	}
}

// Compute the Sync-menu storage line ONCE (call on menu open). statvfs failure -> empty
// string (header simply omits it; never blocks the menu).
static void Lodor_computeStorage(void) {
	struct statvfs vfs;
	lodor_storage_str[0] = '\0';
	if (statvfs(SDCARD_PATH, &vfs) != 0) return;
	unsigned long long frsize = vfs.f_frsize ? vfs.f_frsize : vfs.f_bsize;
	unsigned long long freeb  = (unsigned long long)vfs.f_bavail * frsize;
	unsigned long long total  = (unsigned long long)vfs.f_blocks * frsize;
	if (total == 0) return;
	char fbuf[24], tbuf[24];
	Lodor_fmtBytes(freeb, fbuf, sizeof(fbuf));
	Lodor_fmtBytes(total, tbuf, sizeof(tbuf));
	snprintf(lodor_storage_str, sizeof(lodor_storage_str), "%s free / %s", fbuf, tbuf);
}

// lodor TWO-MENU model: the Lodor/RomM SETTINGS menu (under Tools -> Lodor). The settings
// hub — RomM re-auth/re-pair, Box Art options (placeholder), Keep-WiFi-warm toggle, and the
// RetroAchievements login. Distinct from the routine Sync front-door at root; reuses the same
// Lodor_drawList + modal infra. Routed here when the SAME pak entry is opened from inside Tools.
static int    lodor_show_settings = 0; // Lodor settings menu open (under Tools)
static int    lodor_settings_sel  = 0;

// lodor: RetroAchievements login overlay (softcore-only; the hardcore toggle is deferred).
// Reuses the onboarding keyboard for username then masked password, then shells the engine
// `--ra-login` (password via STDIN, NEVER argv) through the shared progress overlay. The
// status line ("Logged in as <user>") is read straight from config.json's top-level
// ra_username — no engine call — exactly like the boot-gate reads the connection triple.
static int    lodor_show_ra   = 0;   // RetroAchievements overlay open
static int    lodor_ra_sel    = 0;   // selected row in the RA overlay (0=login,1=enable,2=hardcore)
static int    lodor_ra_stage  = 0;   // 0=menu, 1=editing username, 2=editing password
static int    lodor_ra_enable = 1;   // RA_ENABLE toggle (cached; loaded when overlay opens)
static int    lodor_ra_hardcore = 0; // RA_HARDCORE toggle (cached; loaded when overlay opens)
#define LODOR_RA_ROWS 3              // login / RetroAchievements ON-OFF / Hardcore ON-OFF
static char   lodor_ra_user[64]  = ""; // typed RA username (kb target for stage 1)
static char   lodor_ra_pass[128] = ""; // typed RA password (kb target for stage 2; wiped after use)
static char   lodor_ra_status[64] = ""; // current logged-in username from config.json (display only)

// lodor: Sync Feed — a read-only list of recent server saves (game / when / device).
static int    lodor_show_feed = 0;   // feed list open
static int    lodor_feed_sel  = 0;
static Array* lodor_feed_items = NULL; // Entry*: name=human label, path=""

// lodor: NATIVE ONBOARDING WIZARD ------------------------------------------
// A fresh, config-less device boots here instead of into the library (the boot-gate
// runs at launch). The wizard walks the user through connecting to THEIR RomM:
//   Welcome -> Server form -> Pairing code -> Device name -> Working -> library.
// It writes nothing itself — every step shells out through romm-run (so WiFi +
// SSL_CERT_FILE are set) to the engine modes (--set-server / --validate / --pair /
// --register-device / --mirror-*), parses the one RESULT line, and advances or
// re-prompts. The token/code are NEVER rendered or logged (the engine keeps secrets
// off stdout; the launcher never echoes the pairing field's contents beyond the
// transient on-screen edit).
//
// Steps (lodor_onboard_step):
#define LODOR_OB_WELCOME 0  // intro screen, A continues
#define LODOR_OB_SERVER  1  // protocol toggle + hostname keyboard + port + SSL
#define LODOR_OB_PAIR    2  // pairing-code keyboard
#define LODOR_OB_DEVICE  3  // device-name keyboard (default "Mini Flip")
#define LODOR_OB_DONE    4  // terminal: first mirror has run, drop into library
#define LODOR_OB_WIFI    5  // §2 [#38]: native Wi-Fi setup — the FIRST step when offline
// FEATURE 2: Add-Profile = SIGN IN as an EXISTING RomM user (NOT create an account).
// After the profile NAME is set, the LIGHT add-profile flow advances into a username +
// masked-password login (NOT the pairing-code step) and shells the engine
// --login-profile (OAuth2 password grant). These steps are ONLY reached when
// lodor_ob_add_profile is set, so the first-run device onboarding path is untouched.
#define LODOR_OB_LOGIN_USER 6  // Add-Profile: existing RomM username keyboard
#define LODOR_OB_LOGIN_PASS 7  // Add-Profile: masked password keyboard -> --login-profile
// lodor §tailscale (QR onboarding): a 3-mode "How will you reach RomM?" chooser sits
// between WELCOME/WIFI and the existing PAIR step. All three modes set a host, then
// converge on PAIR -> DEVICE -> mirror (unchanged).
#define LODOR_OB_MODE    8  // "How will you reach RomM?" — LAN (default) / Tailscale / Advanced
#define LODOR_OB_LAN     9  // LAN: hostname (+ optional port) keyboard, writes a plain tier-0 host (http)
#define LODOR_OB_TS_HOST 10 // Tailscale: enter the *.ts.net host -> tier-1 host (socks5_proxy + tier)
// (the Tailscale QR sign-in itself runs as a blocking sub-flow, Lodor_obTailscaleFlow,
//  invoked from the MODE chooser; it owns the screen while it scrapes+polls, like the
//  Wi-Fi connect step, so it needs no persistent per-frame step of its own.)

// lodor §tailscale: which mode the user chose in LODOR_OB_MODE (routes the PAIR/back
// transitions back to the right form). 0 = LAN, 1 = Tailscale, 2 = Advanced.
#define LODOR_OB_MODE_LAN 0
#define LODOR_OB_MODE_TS  1
#define LODOR_OB_MODE_ADV 2
static int    lodor_ob_mode       = LODOR_OB_MODE_LAN;
static int    lodor_ob_mode_sel   = 0;   // highlighted row in the MODE chooser (default: LAN)

static int    lodor_show_onboard  = 0;   // 1 = onboarding overlay owns the screen
static int    lodor_onboard_step  = LODOR_OB_WELCOME;

// §2 [#38] Wi-Fi step state. The step has two sub-phases:
//   0 = network list (scanned SSIDs, scroll/paged), 1 = entering password (shared keyboard). The
// connect runs through Lodor_runWithProgress (so the §1 verified verbose status shows). The list is
// built from `romm-run --wifi-scan` output, which is now "<FLAG>\t<SSID>" per line (FLAG = SECURED or
// OPEN, auto-detected from the scan). OPEN networks connect directly (no keyboard); SECURED (and the
// honest unknown->SECURED fallback) open the shared OB keyboard for the PSK.
#define LODOR_OB_WIFI_PSK_MAX 80
#define LODOR_OB_WIFI_SSID_MAX 64
static int    lodor_ob_wifi_phase = 0;        // 0 = SSID list, 1 = password keyboard
static Array* lodor_ob_wifi_list  = NULL;     // Entry*: name=display(lock-prefixed), path=raw SSID, unique="SECURED"/"OPEN"
static int    lodor_ob_wifi_sel   = 0;        // selection in the SSID list (absolute index)
static int    lodor_ob_wifi_start = 0;        // paging window (first visible)
static int    lodor_ob_wifi_end   = 0;        // paging window (one past last)
static char   lodor_ob_wifi_ssid[LODOR_OB_WIFI_SSID_MAX] = ""; // chosen SSID (password phase)
static char   lodor_ob_wifi_psk[LODOR_OB_WIFI_PSK_MAX]    = ""; // typed password (transient)
static int    lodor_ob_wifi_open  = 0;        // 1 = the picked network looked open (no key)

// Server-form model (ported from grout server_address.go, native):
//   protocol toggle (0=http,1=https), hostname (URL keyboard + shortcuts), optional
//   numeric port, SSL verify/skip (shown only on HTTPS). The form has focusable
//   fields; LEFT/RIGHT cycles the protocol & SSL toggles, A opens the keyboard for
//   the text fields. Edits are PRESERVED across a failed validate (the form re-opens
//   with the user's values intact — grout's "validate-on-save with preserved edits").
#define LODOR_OB_HOST_MAX 128   // hostname buffer incl NUL
#define LODOR_OB_PORT_MAX 8     // port buffer incl NUL
#define LODOR_OB_CODE_MAX 16    // pairing-code buffer incl NUL (codes are short)
#define LODOR_OB_NAME_MAX 64    // device-name buffer incl NUL

static int  lodor_ob_https     = 1;    // protocol: 0=http,1=https (default secure)
static int  lodor_ob_insecure  = 0;    // SSL: 0=verify,1=skip (HTTPS only)
static char lodor_ob_host[LODOR_OB_HOST_MAX] = ""; // hostname (no scheme)
static char lodor_ob_port[LODOR_OB_PORT_MAX] = ""; // port string ("" = none)
static char lodor_ob_code[LODOR_OB_CODE_MAX] = ""; // pairing code (transient secret)
static char lodor_ob_name[LODOR_OB_NAME_MAX] = ""; // device name
// FEATURE 2: Add-Profile login buffers (existing-user sign-in). The username is a public
// handle; the password is transient and wiped immediately after it is piped (via env, never
// argv) to the engine. Only used in the lodor_ob_add_profile flow.
#define LODOR_OB_LOGINUSER_MAX 64
#define LODOR_OB_LOGINPASS_MAX 128
static char lodor_ob_login_user[LODOR_OB_LOGINUSER_MAX] = ""; // existing RomM username (Add-Profile)
static char lodor_ob_login_pass[LODOR_OB_LOGINPASS_MAX] = ""; // typed password (transient; wiped after use)

// Server-form field cursor (which row is focused).
#define LODOR_OB_F_PROTO 0
#define LODOR_OB_F_HOST  1
#define LODOR_OB_F_PORT  2
#define LODOR_OB_F_SSL   3
#define LODOR_OB_F_COUNT 4
static int  lodor_ob_field = LODOR_OB_F_HOST; // start on the hostname (the thing you must type)

// Text-entry sub-mode: when a keyboard field is being edited, the wizard borrows the
// existing on-screen keyboard. These hold which buffer is being edited and its cap,
// plus a label/shortcut-mode flag, so ONE keyboard serves host/port/code/name.
static int   lodor_ob_kb_active = 0;     // 1 = keyboard open, editing lodor_ob_kb_buf
static char* lodor_ob_kb_buf    = NULL;  // points at the target buffer (host/port/code/name)
static int   lodor_ob_kb_cap    = 0;     // capacity of that buffer (incl NUL)
static int   lodor_ob_kb_url    = 0;     // 1 = show URL shortcuts (hostname only)
static int   lodor_ob_kb_numeric= 0;     // 1 = numeric-only (port)
static int   lodor_ob_kb_mask   = 0;     // 1 = render the buffer as '*' (passwords) — the value
                                         // is still edited in clear; only the on-screen echo masks
static char  lodor_ob_kb_title[48] = ""; // prompt shown above the keyboard
static int   lodor_ob_kb_cancelled = 0;  // 1 = keyboard was closed via B (cancel), 0 = DONE/START

// Shared on-screen keyboard cursor (row/col), used by BOTH the library-search
// keyboard and the onboarding wizard keyboard. Declared here (before the first user,
// Lodor_obKbOpen) so the wizard helpers compile; the search code below reuses them.
static int   lodor_kb_row       = 0;
static int   lodor_kb_col       = 0;
static int   lodor_kb_layer     = 0; // #97: active keyboard layer (0=abc 1=ABC 2=123/sym); reset per open. Used by Lodor_obKbOpen below, before the lodor_kb_layers[] data is defined.

static void Lodor_freeActions(void) {
	if (lodor_action_items) { EntryArray_free(lodor_action_items); lodor_action_items = NULL; }
	lodor_actions_from_search = 0; // reset context whenever the action menu tears down
}
static void Lodor_freeEmuPick(void) { // §override (#144)
	if (lodor_emupick_items) { EntryArray_free(lodor_emupick_items); lodor_emupick_items = NULL; }
}
static void Lodor_freeSaves(void) {
	if (lodor_saves_items) { EntryArray_free(lodor_saves_items); lodor_saves_items = NULL; }
}
static void Lodor_freeFeed(void) {
	if (lodor_feed_items) { EntryArray_free(lodor_feed_items); lodor_feed_items = NULL; }
}
static void Lodor_freeProfiles(void) {
	if (lodor_profile_items) { EntryArray_free(lodor_profile_items); lodor_profile_items = NULL; }
}
static void Lodor_freeWifiList(void) {
	if (lodor_ob_wifi_list) { EntryArray_free(lodor_ob_wifi_list); lodor_ob_wifi_list = NULL; }
}

// lodor: ONBOARDING BOOT-GATE ----------------------------------------------
// A device is "connected" only when config.json holds a usable triple:
// root_uri AND token AND device_id. We check the file with a dependency-free
// substring scan for those three keys with a non-empty value — NOT a JSON parser
// (the launcher stays lean; the engine owns real parsing). A missing file, an
// unreadable file, or any missing/blank member of the triple => not connected =>
// the launcher enters onboarding instead of the library.
//
// SECURITY: this reads config.json but NEVER copies the token/root_uri anywhere —
// it only tests presence. No value is retained past the scan.
static int Lodor_keyHasValue(const char* json, const char* key) {
	// Find "key" then the following ':' then a non-empty string/number value. This is
	// deliberately forgiving: it accepts "key":"x" and "key": "x" and "key":123, and
	// treats "key":"" / "key":null / absent as "no value".
	char needle[64];
	snprintf(needle, sizeof(needle), "\"%s\"", key);
	const char* p = strstr(json, needle);
	if (!p) return 0;
	p += strlen(needle);
	while (*p==' ' || *p=='\t') p++;
	if (*p != ':') return 0;
	p++;
	while (*p==' ' || *p=='\t' || *p=='\n' || *p=='\r') p++;
	if (*p == '"') {            // string value: non-empty iff next char isn't a closing quote
		return p[1] != '"';
	}
	if (*p=='n' && strncmp(p,"null",4)==0) return 0;
	// number/bool/other token: usable if it's not a closing bracket or comma
	return (*p!='\0' && *p!=',' && *p!='}' && *p!=']');
}

// Lodor_firstHost copies the first object inside the top-level "hosts" array into out
// (NUL-terminated, bounded). Per contract/config.schema.json the connection identity
// (root_uri/token/device_id) and host fields (port/insecure_skip_verify) live under
// hosts[0], NOT at top level — scoping every scan to this object stops a top-level
// homonym from spoofing the gate and keeps a config-less device reading false.
// Brace-matched and string-aware so a '}' inside a value can't terminate it early.
// Returns 1 if a first host object was extracted, 0 if the array/object is absent.
static int Lodor_firstHost(const char* json, char* out, int cap) {
	if (cap > 0) out[0] = '\0';
	const char* p = strstr(json, "\"hosts\"");
	if (!p) return 0;
	p += 7; // past the "hosts" key token
	while (*p && *p != '[') { if (*p=='{' || *p=='}') return 0; p++; }
	if (*p != '[') return 0;
	p++;
	while (*p==' '||*p=='\t'||*p=='\n'||*p=='\r') p++;
	if (*p != '{') return 0; // hosts[0] must be an object
	const char* start = p;
	int depth = 0, instr = 0, esc = 0;
	for (; *p; p++) {
		char c = *p;
		if (instr) {
			if (esc) esc = 0; else if (c=='\\') esc = 1; else if (c=='"') instr = 0;
			continue;
		}
		if (c=='"') instr = 1;
		else if (c=='{') depth++;
		else if (c=='}') { if (--depth == 0) { p++; break; } }
	}
	if (depth != 0) return 0; // unterminated object
	int len = (int)(p - start);
	if (len >= cap) len = cap - 1; // bounded copy (host objects are tiny)
	memcpy(out, start, len);
	out[len] = '\0';
	return 1;
}

// Lodor_isConnected returns 1 when hosts[0] has root_uri AND token AND device_id, all
// non-empty (contract/config.schema.json). The read buffer is generously sized because
// directory_mappings precedes hosts in the file; an undersized read could truncate the
// host object and falsely gate a paired device into onboarding.
static int Lodor_isConnected(void) {
	FILE* f = fopen(LODOR_CONFIG_FILE, "r");
	if (!f) return 0;
	char buf[16384];
	size_t n = fread(buf, 1, sizeof(buf)-1, f);
	fclose(f);
	buf[n] = '\0';
	char host[4096];
	if (!Lodor_firstHost(buf, host, sizeof(host))) return 0;
	return Lodor_keyHasValue(host, "root_uri")
	    && Lodor_keyHasValue(host, "token")
	    && Lodor_keyHasValue(host, "device_id");
}

// Lodor_readRAUser copies the TOP-LEVEL "ra_username" string from config.json into out.
// ra_username is NOT a secret (engine/cmd/lodor-sync/ra.go documents this — --ra-status
// echoes it for exactly this "Logged in as <user>" line); the RA TOKEN is never read here.
// Same dependency-free scan style as the boot-gate. Returns 1 iff a non-empty value found.
static int Lodor_readRAUser(char* out, int cap) {
	if (cap > 0) out[0] = '\0';
	FILE* f = fopen(LODOR_CONFIG_FILE, "r");
	if (!f) return 0;
	char buf[16384];
	size_t n = fread(buf, 1, sizeof(buf)-1, f);
	fclose(f);
	buf[n] = '\0';
	const char* p = strstr(buf, "\"ra_username\"");
	if (!p) return 0;
	p += strlen("\"ra_username\"");
	while (*p==' ' || *p=='\t') p++;
	if (*p != ':') return 0;
	p++;
	while (*p==' ' || *p=='\t' || *p=='\n' || *p=='\r') p++;
	if (*p != '"') return 0; // null / number / absent => treat as not-logged-in
	p++;
	int i = 0;
	while (*p && *p != '"' && i < cap-1) {
		if (*p == '\\' && p[1]) p++; // unescape one level (\" \\ etc.)
		out[i++] = *p++;
	}
	out[i] = '\0';
	return i > 0;
}

// reset wizard state to its first-run defaults (called by the boot-gate and by the
// "Re-connect RomM" Sync entry). Clears the transient pairing-code buffer.
static void Lodor_resetOnboard(void) {
	lodor_onboard_step = LODOR_OB_WELCOME;
	lodor_ob_field     = LODOR_OB_F_HOST;
	// lodor §tailscale: reset the mode chooser to its LAN default on each fresh run.
	lodor_ob_mode      = LODOR_OB_MODE_LAN;
	lodor_ob_mode_sel  = 0;
	lodor_ob_https     = 1;
	lodor_ob_insecure  = 0;
	lodor_ob_host[0]   = '\0';
	lodor_ob_port[0]   = '\0';
	lodor_ob_code[0]   = '\0';
	snprintf(lodor_ob_name, sizeof(lodor_ob_name), "Mini Flip"); // hardware label default
	lodor_ob_kb_active = 0;
	lodor_ob_kb_buf    = NULL;
	// §2 Wi-Fi step state.
	Lodor_freeWifiList();
	lodor_ob_wifi_phase = 0;
	lodor_ob_wifi_sel   = 0; lodor_ob_wifi_start = 0; lodor_ob_wifi_end = 0;
	lodor_ob_wifi_ssid[0] = '\0';
	lodor_ob_wifi_psk[0]  = '\0';
	lodor_ob_wifi_open    = 0;
}

// §2 [#38]: is this device actually online right now? VERIFIED: wlan0 associated/up AND it has an
// IPv4 address. PLAT_isOnline() (operstate==up, the same source as the status-bar icon) plus a real
// inet on wlan0. Used to decide whether the wizard needs the Wi-Fi step at all.
static int Lodor_obIsOnline(void) {
	if (!PLAT_isOnline()) return 0;
	// confirm a real IPv4 lease on wlan0 (associated-but-no-DHCP must NOT count as online).
	FILE* f = popen("ip addr show wlan0 2>/dev/null | grep -c 'inet '", "r");
	int has_ip = 0;
	if (f) { char b[16]; if (fgets(b,sizeof(b),f)) has_ip = atoi(b)>0; pclose(f); }
	return has_ip;
}

// §2 [#38]: pick the FIRST wizard step. If already online -> straight to the RomM Server step.
// If NOT online -> native Wi-Fi setup is the first step (BEFORE server/pair). The B-to-skip escape
// hatch from the Welcome screen remains as a fallback. Called after Lodor_resetOnboard.
static void Lodor_obChooseEntryStep(void) {
	if (Lodor_obIsOnline()) {
		lodor_onboard_step = LODOR_OB_WELCOME; // online: Welcome -> Server (no Wi-Fi step needed)
	} else {
		lodor_onboard_step = LODOR_OB_WELCOME; // Welcome still shows first; A then routes to Wi-Fi
	}
}

// Lodor_obReadStr extracts the string value of "key" from a JSON blob into out
// (bounded). Mirrors Lodor_keyHasValue's forgiving scan: handles "key":"val" and
// "key": "val". Returns 1 on a non-empty value, 0 otherwise (absent/empty/non-string).
// Used ONLY to pre-fill the re-connect form from non-secret fields; never call it on
// token/password.
static int Lodor_obReadStr(const char* json, const char* key, char* out, int cap) {
	char needle[64];
	snprintf(needle, sizeof(needle), "\"%s\"", key);
	const char* pp = strstr(json, needle);
	if (!pp) { if (cap>0) out[0]='\0'; return 0; }
	pp += strlen(needle);
	while (*pp==' '||*pp=='\t') pp++;
	if (*pp!=':') { if (cap>0) out[0]='\0'; return 0; }
	pp++;
	while (*pp==' '||*pp=='\t'||*pp=='\n'||*pp=='\r') pp++;
	if (*pp!='"') { if (cap>0) out[0]='\0'; return 0; }
	pp++;
	int i = 0;
	while (*pp && *pp!='"' && i < cap-1) { out[i++] = *pp++; }
	out[i] = '\0';
	return i > 0;
}

// Lodor_obReadInt extracts an integer value of "key" (e.g. "port": 8443). Returns the
// value or 0 if absent / non-numeric.
static int Lodor_obReadInt(const char* json, const char* key) {
	char needle[64];
	snprintf(needle, sizeof(needle), "\"%s\"", key);
	const char* pp = strstr(json, needle);
	if (!pp) return 0;
	pp += strlen(needle);
	while (*pp==' '||*pp=='\t') pp++;
	if (*pp!=':') return 0;
	pp++;
	while (*pp==' '||*pp=='\t'||*pp=='\n'||*pp=='\r') pp++;
	return atoi(pp); // atoi stops at the first non-digit; 0 if none
}

// Lodor_obReadBool extracts a JSON bool value of "key" (true/false). Returns 1 only
// for an explicit true, else 0.
static int Lodor_obReadBool(const char* json, const char* key) {
	char needle[64];
	snprintf(needle, sizeof(needle), "\"%s\"", key);
	const char* pp = strstr(json, needle);
	if (!pp) return 0;
	pp += strlen(needle);
	while (*pp==' '||*pp=='\t') pp++;
	if (*pp!=':') return 0;
	pp++;
	while (*pp==' '||*pp=='\t'||*pp=='\n'||*pp=='\r') pp++;
	return strncmp(pp, "true", 4)==0;
}

// Lodor_prefillOnboard seeds the wizard's server form from an EXISTING config so the
// "Re-connect RomM" path is an edit, not a retype. It resets to defaults first, then
// overlays the non-secret host fields (scheme->protocol toggle, root_uri host+subpath
// into the hostname field, port, insecure_skip_verify->SSL). It NEVER reads or shows
// the token or any pair code. On a missing/unreadable config it leaves the reset
// defaults (blank), so a fresh device degrades gracefully.
static void Lodor_prefillOnboard(void) {
	Lodor_resetOnboard();
	FILE* f = fopen(LODOR_CONFIG_FILE, "r");
	if (!f) return;
	char buf[16384];
	size_t n = fread(buf, 1, sizeof(buf)-1, f);
	fclose(f);
	buf[n] = '\0';

	// contract/config.schema.json: host fields (root_uri/port/insecure_skip_verify) live
	// under hosts[0]; scope the prefill reads to the first host object.
	char host[4096];
	if (!Lodor_firstHost(buf, host, sizeof(host))) return;

	char root[LODOR_OB_HOST_MAX];
	if (Lodor_obReadStr(host, "root_uri", root, sizeof(root))) {
		// split scheme off root_uri into the protocol toggle; the remainder (host +
		// any subpath) becomes the hostname field verbatim.
		const char* rest = root;
		if (strncasecmp(rest, "https://", 8)==0) { lodor_ob_https = 1; rest += 8; }
		else if (strncasecmp(rest, "http://", 7)==0) { lodor_ob_https = 0; rest += 7; }
		snprintf(lodor_ob_host, sizeof(lodor_ob_host), "%s", rest);
	}
	int port = Lodor_obReadInt(host, "port");
	if (port > 0) snprintf(lodor_ob_port, sizeof(lodor_ob_port), "%d", port);
	// insecure_skip_verify only meaningful on HTTPS; the form hides SSL on HTTP anyway.
	lodor_ob_insecure = Lodor_obReadBool(host, "insecure_skip_verify") ? 1 : 0;
}

// open the shared keyboard against a target buffer (host/port/code/name).
static void Lodor_obKbOpen(char* buf, int cap, const char* title, int url, int numeric) {
	lodor_ob_kb_active  = 1;
	lodor_ob_kb_buf     = buf;
	lodor_ob_kb_cap     = cap;
	lodor_ob_kb_url     = url;
	lodor_ob_kb_numeric = numeric;
	lodor_ob_kb_mask    = 0; // default: clear echo. The RA password field re-enables it after open.
	snprintf(lodor_ob_kb_title, sizeof(lodor_ob_kb_title), "%s", title);
	lodor_kb_row = 0; lodor_kb_col = 0; lodor_kb_layer = 0; // reuse the search keyboard cursor statics; start on lowercase (#97)
}

// URL one-tap shortcuts (grout's romm./.com/.org/.net/.ts.net). Appended to the
// hostname buffer. Rendered as a 5-button row above the key grid in URL mode.
static const char* lodor_ob_url_shortcuts[5] = { "romm.", ".com", ".net", ".org", ".ts.net" };
#define LODOR_OB_URL_SC_COUNT 5
static int lodor_ob_sc_sel = 0; // selected shortcut column when the shortcut row is focused

// compose the full server URL ("http://"|"https://" + host[/subpath]) into out. The
// hostname field may carry a SUBPATH (e.g. "example.com/romm") — that path is kept
// VERBATIM (never truncated at the first '/'). The scheme comes from the toggle, so
// we strip an accidental leading "http://"/"https://" the user typed into the host,
// strip a single trailing '/', and trim surrounding whitespace. The port is applied
// separately via --port and never appears here.
static void Lodor_obBuildURL(char* out, int cap) {
	const char* h = lodor_ob_host;
	// trim leading whitespace
	while (*h==' ' || *h=='\t') h++;
	// strip a stray scheme typed into the hostname (case-insensitive) — the protocol
	// toggle owns the scheme; a doubled "https://https://..." is the bug we prevent.
	if (strncasecmp(h, "https://", 8)==0) h += 8;
	else if (strncasecmp(h, "http://", 7)==0) h += 7;
	// copy into a local scratch so we can trim the tail without mutating lodor_ob_host
	char host[LODOR_OB_HOST_MAX];
	int n = 0;
	while (h[n] && n < (int)sizeof(host)-1) { host[n] = h[n]; n++; }
	host[n] = '\0';
	// trim trailing whitespace
	while (n>0 && (host[n-1]==' ' || host[n-1]=='\t')) host[--n] = '\0';
	// strip a single trailing '/'
	if (n>0 && host[n-1]=='/') host[--n] = '\0';
	snprintf(out, cap, "%s%s", lodor_ob_https ? "https://" : "http://", host);
}

// lodor: LIBRARY SEARCH overlay --------------------------------------------
// SELECT on the main menu opens a native search: an on-screen keyboard to type a
// query, then an on-demand case-insensitive substring scan of the whole mirrored
// Roms/ stub tree. Results render via Lodor_drawList; selecting one routes through
// the SAME download-then-launch path as tapping that game's stub in the menu.
// RAM-bounded: results capped at 100, freed on every close/refresh; the scan is
// transient (opendir/readdir/match/push/closedir) with no in-memory index.
#define LODOR_SEARCH_QMAX 64    // query buffer incl. NUL (63 typeable chars)
#define LODOR_SEARCH_CAP  100   // hard cap on results
#define LODOR_KB_ROWS     5
#define LODOR_KB_COLS     10
static int    lodor_show_search   = 0;   // search overlay open
static int    lodor_search_phase  = 0;   // 0=typing (keyboard), 1=results list
static char   lodor_search_q[LODOR_SEARCH_QMAX] = "";
static int    lodor_search_sel    = 0;   // selection in the results list
static int    lodor_search_start  = 0;   // first visible row (paging)
static int    lodor_search_end    = 0;   // one past last visible row (paging)
static int    lodor_search_capped = 0;   // 1 if the scan hit LODOR_SEARCH_CAP
static Array* lodor_search_results = NULL; // Entry*: ENTRY_ROM, path=full stub path

// keyboard layout: 4 grid rows of 10 keys + a 5th special row.
// Row 4 holds the 3 special keys at fixed columns: SPACE(0), DEL(4), SEARCH(8).
// lodor #97: the grid carries THREE switchable layers — lowercase, UPPERCASE, and
// numbers/symbols — so case-sensitive entries (RetroAchievements login, Wi-Fi PSK,
// RomM password) can reach mixed case + the symbols a password needs. L1/R1 cycle the
// active layer (abc -> ABC -> 123/sym -> abc); the layer resets to lowercase every time
// a keyboard opens, so nothing persists between entries. The special row (space/del/done)
// is layer-independent and stays addressed by column.
#define LODOR_KB_LAYERS 3
static const char lodor_kb_layers[LODOR_KB_LAYERS][4][LODOR_KB_COLS+1] = {
	{ "abcdefghij", "klmnopqrst", "uvwxyz0123", "456789-./_" }, // 0: lowercase
	{ "ABCDEFGHIJ", "KLMNOPQRST", "UVWXYZ0123", "456789-./_" }, // 1: UPPERCASE
	{ "1234567890", "!@#$%^&*()", "-_=+[]{}<>", ".,?:;'\"/\\~" }, // 2: numbers/symbols
};
// lodor_kb_layer itself is forward-declared up by lodor_kb_row/col (used by Lodor_obKbOpen,
// which precedes this data block). 0=abc 1=ABC 2=123/sym; reset to 0 on every keyboard open.
static const char* lodor_kb_layer_name[LODOR_KB_LAYERS] = { "abc", "ABC", "123" };
#define LODOR_KB_CH(r,c) (lodor_kb_layers[lodor_kb_layer][(r)][(c)])
#define LODOR_KB_SPACE_COL  0
#define LODOR_KB_DEL_COL    4
#define LODOR_KB_GO_COL     8

static void Lodor_freeSearchResults(void) {
	if (lodor_search_results) { EntryArray_free(lodor_search_results); lodor_search_results = NULL; }
}
// reset all search state (called when SELECT opens the overlay).
static void Lodor_resetSearch(void) {
	Lodor_freeSearchResults();
	lodor_search_q[0] = '\0';
	lodor_kb_row = 0; lodor_kb_col = 0; lodor_kb_layer = 0; // start on lowercase (#97)
	lodor_search_phase = 0;
	lodor_search_sel = 0; lodor_search_start = 0; lodor_search_end = 0;
	lodor_search_capped = 0;
}
// close the whole overlay and free results.
static void Lodor_closeSearch(void) {
	lodor_show_search = 0;
	Lodor_freeSearchResults();
}

// portable case-insensitive substring: returns 1 if needle is in haystack.
// needle is expected already-lowercased by the caller; we lower haystack chars.
static int Lodor_ciContains(const char* haystack, const char* lc_needle) {
	if (!lc_needle[0]) return 0;
	size_t nl = strlen(lc_needle);
	for (const char* h = haystack; *h; h++) {
		size_t i = 0;
		while (i<nl && h[i] && (char)tolower((unsigned char)h[i])==lc_needle[i]) i++;
		if (i==nl) return 1;
	}
	return 0;
}

// on-demand scan of ROMS_PATH (one level of system subdirs, then their files).
// filename string match only -- no stat() per file (stubs are 0-byte, thousands of them).
static void Lodor_runScan(void) {
	Lodor_freeSearchResults();
	lodor_search_results = Array_new();
	lodor_search_sel = 0; lodor_search_start = 0; lodor_search_end = 0;
	lodor_search_capped = 0;

	if (strlen(lodor_search_q) < 1) return; // nothing to match

	char needle[LODOR_SEARCH_QMAX];
	for (int i=0; lodor_search_q[i] && i<LODOR_SEARCH_QMAX-1; i++)
		needle[i] = (char)tolower((unsigned char)lodor_search_q[i]);
	needle[ strlen(lodor_search_q)<LODOR_SEARCH_QMAX ? strlen(lodor_search_q) : LODOR_SEARCH_QMAX-1 ] = '\0';

	DIR* rh = opendir(ROMS_PATH);
	if (!rh) return;
	struct dirent* sub;
	while ((sub = readdir(rh)) != NULL) {
		if (hide(sub->d_name)) continue; // skips dotfiles + special paks
		char subpath[MAX_PATH];
		snprintf(subpath, sizeof(subpath), "%s/%s", ROMS_PATH, sub->d_name);
		DIR* fh = opendir(subpath); // skips non-directories (NULL) implicitly
		if (!fh) continue;
		struct dirent* fp;
		while ((fp = readdir(fh)) != NULL) {
			if (fp->d_name[0]=='.') continue;  // dotfiles incl. . and ..
			if (hide(fp->d_name)) continue;
			if (!Lodor_ciContains(fp->d_name, needle)) continue;
			char full_path[MAX_PATH];
			snprintf(full_path, sizeof(full_path), "%s/%s", subpath, fp->d_name);
			Entry* e = Entry_new(full_path, ENTRY_ROM);
			// annotate display name with the system (parent dir) so duplicate-named
			// games across systems are distinguishable, e.g. "Sonic (Genesis)".
			{
				char labeled[320];
				snprintf(labeled, sizeof(labeled), "%s (%s)", e->name, sub->d_name);
				free(e->name); e->name = strdup(labeled);
			}
			Array_push(lodor_search_results, e);
			if (lodor_search_results->count >= LODOR_SEARCH_CAP) {
				lodor_search_capped = 1;
				break;
			}
		}
		closedir(fh);
		if (lodor_search_capped) break;
	}
	closedir(rh);
	EntryArray_sort(lodor_search_results);
}

// render the on-screen keyboard (phase 0): query line, key grid w/ selection pill, hint.
static void Lodor_drawKeyboard(SDL_Surface* screen) {
	GFX_clear(screen);
	int ow = GFX_blitHardwareGroup(screen, 0);
	(void)ow;

	// query line: "Search: <q>_"
	char qline[LODOR_SEARCH_QMAX+16];
	snprintf(qline, sizeof(qline), "Search: %s_", lodor_search_q);
	char qbuf[320];
	GFX_truncateText(font.large, qline, qbuf,
		screen->w - SCALE1(PADDING*2), SCALE1(BUTTON_PADDING*2));
	SDL_Surface* qt = TTF_RenderUTF8_Blended(font.large, qbuf, COLOR_WHITE);
	if (qt) {
		SDL_BlitSurface(qt, NULL, screen, &(SDL_Rect){
			SCALE1(PADDING+BUTTON_PADDING), SCALE1(PADDING+4)});
		SDL_FreeSurface(qt);
	}

	// key grid -- 4 letter/number rows then the special row, starting at row 1.
	int cellw = (screen->w - SCALE1(PADDING*2)) / LODOR_KB_COLS;
	for (int r=0; r<LODOR_KB_ROWS; r++) {
		int y = SCALE1(PADDING + (r+1)*PILL_SIZE);
		if (r < 4) {
			for (int c=0; c<LODOR_KB_COLS; c++) {
				char ch[2] = { LODOR_KB_CH(r,c), '\0' };
				int x = SCALE1(PADDING) + c*cellw;
				SDL_Color color = COLOR_WHITE;
				if (r==lodor_kb_row && c==lodor_kb_col) {
					GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){ x, y, cellw, SCALE1(PILL_SIZE) });
					color = COLOR_BLACK;
				}
				SDL_Surface* t = TTF_RenderUTF8_Blended(font.large, ch, color);
				if (t) {
					SDL_BlitSurface(t, NULL, screen, &(SDL_Rect){
						x + (cellw - t->w)/2, y + (SCALE1(PILL_SIZE) - t->h)/2 });
					SDL_FreeSurface(t);
				}
			}
		} else {
			// special row: 3 labelled keys, evenly tiled across the usable width so the
			// rightmost ([SEARCH]) ends within the right margin (screen->w - SCALE1(PADDING))
			// on both 640px and 752px panels. Cursor still tracks the fixed columns (0/4/8);
			// we map lodor_kb_col -> k for the highlight.
			const char* labels[3] = { "[space]", "[del]", "[SEARCH]" };
			int cols[3] = { LODOR_KB_SPACE_COL, LODOR_KB_DEL_COL, LODOR_KB_GO_COL };
			int usable = screen->w - SCALE1(PADDING*2);
			int gap    = SCALE1(PADDING);
			int keyw   = (usable - 2*gap) / 3; // 3 keys + 2 gaps fill the usable width
			for (int k=0; k<3; k++) {
				int c = cols[k];
				int x = SCALE1(PADDING) + k*(keyw + gap);
				int w = keyw;
				// keep the rightmost key strictly inside the margin even after integer rounding.
				if (x + w > screen->w - SCALE1(PADDING)) w = screen->w - SCALE1(PADDING) - x;
				SDL_Color color = COLOR_WHITE;
				if (r==lodor_kb_row && c==lodor_kb_col) {
					GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){ x, y, w, SCALE1(PILL_SIZE) });
					color = COLOR_BLACK;
				}
				SDL_Surface* t = TTF_RenderUTF8_Blended(font.large, (char*)labels[k], color);
				if (t) {
					SDL_BlitSurface(t, &(SDL_Rect){0,0,w-SCALE1(BUTTON_PADDING),t->h}, screen, &(SDL_Rect){
						x + SCALE1(BUTTON_PADDING), y + (SCALE1(PILL_SIZE) - t->h)/2 });
					SDL_FreeSurface(t);
				}
			}
		}
	}
	// #97: right pill = type/back; left pill = layer toggle + START-submit. The layer
	// hint doubles as the active-layer indicator (abc/ABC/123).
	GFX_blitButtonGroup((char*[]){ "B","BACK", "A","TYPE", NULL }, 1, screen, 1);
	GFX_blitButtonGroup((char*[]){ "START","SEARCH", "L/R",(char*)lodor_kb_layer_name[lodor_kb_layer], NULL }, 1, screen, 0);
	GFX_flip(screen);
}

// snap the special-row cursor onto one of the 3 valid special columns.
static void Lodor_kbSnapSpecial(void) {
	int valid[3] = { LODOR_KB_SPACE_COL, LODOR_KB_DEL_COL, LODOR_KB_GO_COL };
	for (int i=0;i<3;i++) if (lodor_kb_col==valid[i]) return;
	// nearest valid column
	int best = valid[0], bestd = LODOR_KB_COLS;
	for (int i=0;i<3;i++) { int d = lodor_kb_col-valid[i]; if (d<0) d=-d; if (d<bestd){bestd=d;best=valid[i];} }
	lodor_kb_col = best;
}

// lodor: ONBOARDING RENDERERS ----------------------------------------------
// Render the shared wizard keyboard against lodor_ob_kb_buf. Same key grid as the
// search keyboard (Lodor_drawKeyboard), but: (a) the edit line shows the wizard
// prompt + current buffer, (b) in URL mode a row of one-tap shortcuts sits between
// the prompt and the grid (focused via UP onto row -1, tracked by lodor_ob_sc_sel),
// (c) the [SEARCH] special key reads "[DONE]". Numeric mode hides letters by only
// accepting digit presses (the grid still draws; non-digit keys are inert).
static void Lodor_obDrawKeyboard(SDL_Surface* screen) {
	GFX_clear(screen);
	GFX_blitHardwareGroup(screen, 0);

	// prompt + current value line. The pairing-code field is a secret — but it is the
	// value the USER is actively typing and must see to correct typos, exactly like
	// grout's code field. It is shown here ONLY (never logged, never passed on a
	// command line that reaches a log) and cleared from memory once pairing completes.
	char line[LODOR_OB_HOST_MAX+48];
	const char* lodor_kb_shown = lodor_ob_kb_buf ? lodor_ob_kb_buf : "";
	char lodor_kb_masked[LODOR_OB_HOST_MAX+1];
	if (lodor_ob_kb_mask && lodor_ob_kb_buf) {
		int mn = (int)strlen(lodor_ob_kb_buf);
		if (mn > (int)sizeof(lodor_kb_masked)-1) mn = sizeof(lodor_kb_masked)-1;
		for (int mi=0; mi<mn; mi++) lodor_kb_masked[mi] = '*';
		lodor_kb_masked[mn] = '\0';
		lodor_kb_shown = lodor_kb_masked;
	}
	snprintf(line, sizeof(line), "%s %s_", lodor_ob_kb_title, lodor_kb_shown);
	char lbuf[320];
	GFX_truncateText(font.large, line, lbuf, screen->w - SCALE1(PADDING*2), SCALE1(BUTTON_PADDING*2));
	SDL_Surface* lt = TTF_RenderUTF8_Blended(font.large, lbuf, COLOR_WHITE);
	if (lt) { SDL_BlitSurface(lt, NULL, screen, &(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), SCALE1(PADDING+4)}); SDL_FreeSurface(lt); }

	int grid_top_row = 1; // grid starts one PILL row below the prompt
	// URL shortcut row (only in URL mode): 5 pills tiled across the width.
	if (lodor_ob_kb_url) {
		int y = SCALE1(PADDING + 1*PILL_SIZE);
		int usable = screen->w - SCALE1(PADDING*2);
		int gap = SCALE1(PADDING/2); if (gap<SCALE1(4)) gap=SCALE1(4);
		int keyw = (usable - (LODOR_OB_URL_SC_COUNT-1)*gap) / LODOR_OB_URL_SC_COUNT;
		for (int k=0; k<LODOR_OB_URL_SC_COUNT; k++) {
			int x = SCALE1(PADDING) + k*(keyw+gap);
			SDL_Color color = COLOR_WHITE;
			if (lodor_kb_row==-1 && lodor_ob_sc_sel==k) {
				GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){ x, y, keyw, SCALE1(PILL_SIZE) });
				color = COLOR_BLACK;
			}
			SDL_Surface* t = TTF_RenderUTF8_Blended(font.large, (char*)lodor_ob_url_shortcuts[k], color);
			if (t) {
				SDL_BlitSurface(t, &(SDL_Rect){0,0,keyw-SCALE1(4),t->h}, screen,
					&(SDL_Rect){ x + ((keyw-t->w)/2 > 0 ? (keyw-t->w)/2 : 0), y + (SCALE1(PILL_SIZE)-t->h)/2 });
				SDL_FreeSurface(t);
			}
		}
		grid_top_row = 2; // push the grid down one row to make room for the shortcut row
	}

	// key grid (rows 0..3 letters/digits, row 4 special) — same geometry as search.
	int cellw = (screen->w - SCALE1(PADDING*2)) / LODOR_KB_COLS;
	for (int r=0; r<LODOR_KB_ROWS; r++) {
		int y = SCALE1(PADDING + (grid_top_row+r)*PILL_SIZE);
		if (r < 4) {
			for (int c=0; c<LODOR_KB_COLS; c++) {
				char ch[2] = { LODOR_KB_CH(r,c), '\0' };
				int x = SCALE1(PADDING) + c*cellw;
				SDL_Color color = COLOR_WHITE;
				// dim non-digit keys in numeric mode so the port field reads clearly.
				int inert = lodor_ob_kb_numeric && !(ch[0]>='0' && ch[0]<='9');
				if (r==lodor_kb_row && c==lodor_kb_col) {
					GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){ x, y, cellw, SCALE1(PILL_SIZE) });
					color = COLOR_BLACK;
				} else if (inert) {
					color = COLOR_GRAY;
				}
				SDL_Surface* t = TTF_RenderUTF8_Blended(font.large, ch, color);
				if (t) { SDL_BlitSurface(t, NULL, screen, &(SDL_Rect){ x + (cellw - t->w)/2, y + (SCALE1(PILL_SIZE) - t->h)/2 }); SDL_FreeSurface(t); }
			}
		} else {
			const char* labels[3] = { "[space]", "[del]", "[DONE]" };
			int cols[3] = { LODOR_KB_SPACE_COL, LODOR_KB_DEL_COL, LODOR_KB_GO_COL };
			int usable = screen->w - SCALE1(PADDING*2);
			int gap = SCALE1(PADDING);
			int keyw = (usable - 2*gap) / 3;
			for (int k=0; k<3; k++) {
				int c = cols[k];
				int x = SCALE1(PADDING) + k*(keyw + gap);
				int w = keyw;
				if (x + w > screen->w - SCALE1(PADDING)) w = screen->w - SCALE1(PADDING) - x;
				SDL_Color color = COLOR_WHITE;
				if (r==lodor_kb_row && c==lodor_kb_col) {
					GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){ x, y, w, SCALE1(PILL_SIZE) });
					color = COLOR_BLACK;
				}
				SDL_Surface* t = TTF_RenderUTF8_Blended(font.large, (char*)labels[k], color);
				if (t) { SDL_BlitSurface(t, &(SDL_Rect){0,0,w-SCALE1(BUTTON_PADDING),t->h}, screen, &(SDL_Rect){ x + SCALE1(BUTTON_PADDING), y + (SCALE1(PILL_SIZE) - t->h)/2 }); SDL_FreeSurface(t); }
			}
		}
	}
	// #97: right pill = type/back; left pill = layer toggle + START-submit. START confirms
	// the field (same as the on-grid [DONE] key); the layer hint shows the active layer.
	GFX_blitButtonGroup((char*[]){ "B","BACK", "A","TYPE", NULL }, 1, screen, 1);
	GFX_blitButtonGroup((char*[]){ "START","SUBMIT", "L/R",(char*)lodor_kb_layer_name[lodor_kb_layer], NULL }, 1, screen, 0);
	GFX_flip(screen);
}

// Render the server-address form: a 4-row field list (Protocol / Hostname / Port /
// SSL), focused row highlighted. SSL row only appears on HTTPS (grout's conditional
// visibility). LEFT/RIGHT cycles the focused toggle; A opens the keyboard on a text
// field; START submits. Reuses the pill + button-group primitives only.
static void Lodor_obDrawServerForm(SDL_Surface* screen) {
	GFX_clear(screen);
	GFX_blitHardwareGroup(screen, 0);

	SDL_Surface* tt = TTF_RenderUTF8_Blended(font.large, "Connect to RomM", COLOR_WHITE);
	if (tt) { SDL_BlitSurface(tt, NULL, screen, &(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), SCALE1(PADDING+4)}); SDL_FreeSurface(tt); }

	// Build the visible rows. SSL hidden unless HTTPS.
	int ssl_visible = lodor_ob_https;
	const char* names[LODOR_OB_F_COUNT];
	char        vals[LODOR_OB_F_COUNT][96];
	int         fields[LODOR_OB_F_COUNT];
	int rowcount = 0;
	names[rowcount]="Protocol"; snprintf(vals[rowcount],96,"%s", lodor_ob_https?"HTTPS":"HTTP"); fields[rowcount]=LODOR_OB_F_PROTO; rowcount++;
	names[rowcount]="Hostname"; snprintf(vals[rowcount],96,"%s", lodor_ob_host[0]?lodor_ob_host:"(set me)"); fields[rowcount]=LODOR_OB_F_HOST; rowcount++;
	names[rowcount]="Port";     snprintf(vals[rowcount],96,"%s", lodor_ob_port[0]?lodor_ob_port:"(none)"); fields[rowcount]=LODOR_OB_F_PORT; rowcount++;
	if (ssl_visible) { names[rowcount]="SSL"; snprintf(vals[rowcount],96,"%s", lodor_ob_insecure?"Skip Verification":"Verify"); fields[rowcount]=LODOR_OB_F_SSL; rowcount++; }

	for (int i=0;i<rowcount;i++) {
		int row = i+1;
		int y = SCALE1(PADDING+(row*PILL_SIZE));
		char rowtxt[160];
		snprintf(rowtxt, sizeof(rowtxt), "%s:  %s", names[i], vals[i]);
		char rbuf[200];
		int tw = GFX_truncateText(font.large, rowtxt, rbuf, screen->w - SCALE1(PADDING*2), SCALE1(BUTTON_PADDING*2));
		int max_width = MIN(screen->w - SCALE1(PADDING*2), tw);
		SDL_Color color = COLOR_WHITE;
		if (fields[i]==lodor_ob_field) {
			GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){ SCALE1(PADDING), y, max_width, SCALE1(PILL_SIZE) });
			color = COLOR_BLACK;
		}
		SDL_Surface* t = TTF_RenderUTF8_Blended(font.large, rbuf, color);
		if (t) { SDL_BlitSurface(t, &(SDL_Rect){0,0,max_width-SCALE1(BUTTON_PADDING*2),t->h}, screen, &(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), y+SCALE1(4)}); SDL_FreeSurface(t); }
	}

	// footer hints adapt to the focused field type.
	if (lodor_ob_field==LODOR_OB_F_PROTO || lodor_ob_field==LODOR_OB_F_SSL)
		GFX_blitButtonGroup((char*[]){ "B","BACK", "LEFT/RIGHT","CHANGE", "START","CONNECT", NULL }, 1, screen, 1);
	else
		GFX_blitButtonGroup((char*[]){ "B","BACK", "A","EDIT", "START","CONNECT", NULL }, 1, screen, 1);
	GFX_flip(screen);
}

// lodor §3 [#39]: OVERSCAN-SAFE wizard text. GFX_blitMessage centers each line on the dst_rect
// and does NOT wrap or truncate, so any line wider than the panel clips at the edge (confirmed on
// the 640x480 Mini Flip). This helper (a) constrains every wizard screen to a SAFE AREA (sane
// margins so the status bar and the button-hint row never collide with text and nothing reaches the
// physical panel edge) and (b) re-wraps each paragraph to the safe width via GFX_wrapText so long
// lines fold instead of clipping. Existing '\n' breaks are honored (paragraphs wrapped independently;
// blank lines preserved). Use this for Welcome + the server form title + pair/device screens.
#define LODOR_OB_SAFE_TOP    (SCALE1(PADDING) + SCALE1(PILL_SIZE))   // clear the status bar row
#define LODOR_OB_SAFE_BOTTOM (SCALE1(PADDING) + SCALE1(PILL_SIZE))   // clear the button-hint row
#define LODOR_OB_SAFE_SIDE   (SCALE1(PADDING*2))                     // L/R margin off the panel edge
static void Lodor_obMessage(SDL_Surface* screen, const char* msg) {
	int safe_x = LODOR_OB_SAFE_SIDE;
	int safe_w = screen->w - LODOR_OB_SAFE_SIDE*2;
	if (safe_w < SCALE1(40)) safe_w = SCALE1(40);
	int safe_y = LODOR_OB_SAFE_TOP;
	int safe_h = screen->h - LODOR_OB_SAFE_TOP - LODOR_OB_SAFE_BOTTOM;
	if (safe_h < SCALE1(PILL_SIZE)) safe_h = SCALE1(PILL_SIZE);

	// Wrap each '\n'-delimited paragraph to safe_w, rejoining with '\n'. GFX_wrapText mutates its
	// argument in place, so we copy each segment into a scratch buffer first. GFX_blitMessage caps
	// at TEXT_BOX_MAX_ROWS(16); we cap our own line count well under that to stay safe.
	char wrapped[1024]; wrapped[0]='\0';
	int wlen = 0, lines = 0;
	const char* p = msg;
	while (p && lines < 14) {
		const char* nl = strchr(p, '\n');
		int seglen = nl ? (int)(nl - p) : (int)strlen(p);
		char seg[512];
		if (seglen > (int)sizeof(seg)-1) seglen = sizeof(seg)-1;
		memcpy(seg, p, seglen); seg[seglen] = '\0';
		if (seg[0]=='\0') {
			// blank line (paragraph break) — emit a single empty row.
			if (wlen < (int)sizeof(wrapped)-2) { wrapped[wlen++]='\n'; wrapped[wlen]='\0'; }
			lines++;
		} else {
			GFX_wrapText(font.large, seg, safe_w, 6); // fold this paragraph to the safe width
			// append seg (which may now contain its own '\n's) + a trailing '\n'
			for (int i=0; seg[i] && wlen < (int)sizeof(wrapped)-2; i++) {
				wrapped[wlen++] = seg[i];
				if (seg[i]=='\n') lines++;
			}
			if (wlen < (int)sizeof(wrapped)-2) { wrapped[wlen++]='\n'; wrapped[wlen]='\0'; }
			lines++;
		}
		if (!nl) break;
		p = nl + 1;
	}
	// strip the trailing '\n' so GFX_blitMessage centers correctly.
	if (wlen>0 && wrapped[wlen-1]=='\n') wrapped[wlen-1]='\0';

	GFX_blitMessage(font.large, wrapped, screen, &(SDL_Rect){ safe_x, safe_y, safe_w, safe_h });
}

// lodor §11 (box art): build the on-card artwork path for a ROM —
// <dir>/.media/<basename-without-ext>.png — into out (size cap). Returns 1 on success,
// 0 if the path is unusable. This is the Lodor engine's cover contract (pkg cover
// MediaPath): the engine's --mirror-catalog / --download fetch each game's RomM cover
// and save it here, and the launcher reads it back. Matching them exactly is the
// contract — engine writes where the launcher reads. (The .media layout is also the
// convention NextUI-family cards use, so art survives card moves between frontends.)
static int Lodor_mediaPath(const char* rompath, char* out, size_t outsz) {
	if (!rompath || !rompath[0]) return 0;
	char dir[MAX_PATH];
	strncpy(dir, rompath, sizeof(dir)-1); dir[sizeof(dir)-1]='\0';
	char* slash = strrchr(dir, '/');
	if (!slash) return 0;
	*slash = '\0';                 // dir now holds the parent directory
	const char* base = slash + 1;  // base now holds the filename
	char stem[MAX_PATH];
	strncpy(stem, base, sizeof(stem)-1); stem[sizeof(stem)-1]='\0';
	char* dot = strrchr(stem, '.');
	if (dot) *dot = '\0';          // strip the extension (the .media stem carries no ext)
	if (!stem[0]) return 0;
	int n = snprintf(out, outsz, "%s/.media/%s.png", dir, stem);
	return (n>0 && (size_t)n < outsz);
}

// lodor §artcache (#148): off-UI-thread art decode + byte-bounded LRU cache.
// Behavior-inspired by NextUI's async thumbnail loading; independent implementation.
// A single SDL worker thread does the IMG_Load (the decode is the expensive part) so the
// UI thread never blocks; decoded surfaces land in an MRU-first list bounded by BYTES,
// so the entry count follows from real pixel payload (covers are engine-pre-scaled to
// <=320px, screenshots are <=screen-size). One request is in flight at a time; the queue
// is the CURRENT request plus two prefetch slots (selected+/-1), and a superseded current
// decode is dropped by sequence, never delivered. Oversized surfaces are scaled down at
// insert (aspect-preserving) so an out-of-spec asset can't blow the budget or the layout;
// small switcher previews may be integer-upscaled toward their slot (grow) via the
// common/scaler.c software scalers. SDL 1.2 threads/mutex/cond — software-safe, no GL.
//
// RAM worst case (documented at the budget): the budget bounds resident pixel payload.
//   covers      <=320x320x4B RGBA  ~= 400KB -> >=10 resident at 4MB, >=20 at 8MB
//   previews    <=640x480x2B 565    = 600KB ->  >=6 resident at 4MB, >=13 at 8MB
// plus ONE transient in-flight decode (<=1.2MB RGBA at screen size) on the worker,
// freed before the next dequeue. The launcher is not resident during gameplay, so this
// costs zero in-game RAM.
#define LODOR_ART_BUDGET_MIYOOMINI (4*1024*1024) // 128MB device — keep the cache lean
#define LODOR_ART_BUDGET_DEFAULT   (8*1024*1024)
#define LODOR_ART_QUEUE 3 // [0] = current request, [1..2] = prefetch (selected +/- 1)
typedef struct LodorArtEntry {
	struct LodorArtEntry* next;   // MRU-first singly-linked list (small N — bytes-bounded)
	SDL_Surface* surf;            // cache-owned
	size_t bytes;                 // resident pixel payload (h * pitch)
	char path[MAX_PATH];
} LodorArtEntry;
typedef struct LodorArtReq {
	char path[MAX_PATH];          // "" = slot empty
	int max_w, max_h;             // display slot — downscale-on-insert cap
	int grow;                     // 1 = integer-upscale small surfaces toward the slot
	int seq;                      // sequence at enqueue (stale-drop for the current slot)
} LodorArtReq;
static SDL_Thread*  lodor_art_thread = NULL;
static SDL_mutex*   lodor_art_mutex  = NULL;
static SDL_cond*    lodor_art_cond   = NULL;
static volatile int lodor_art_shutdown = 0;
static LodorArtEntry* lodor_art_head = NULL;             // MRU first
static size_t       lodor_art_bytes  = 0;                // resident payload
static size_t       lodor_art_budget = 0;                // set once in Lodor_artInit
static LodorArtReq  lodor_art_queue[LODOR_ART_QUEUE];    // guarded by lodor_art_mutex
static int          lodor_art_seq = 0;                   // bumps per CURRENT request
static char         lodor_art_pin[MAX_PATH] = {0};       // last surface handed to the UI — never evicted
static int          lodor_art_ready = 0;                 // a decode landed since last poll

// cache list ops — caller holds lodor_art_mutex.
static LodorArtEntry* Lodor_artFind(const char* path) {
	LodorArtEntry* e = lodor_art_head;
	LodorArtEntry* prev = NULL;
	while (e) {
		if (strcmp(e->path, path)==0) {
			if (prev) { prev->next = e->next; e->next = lodor_art_head; lodor_art_head = e; } // bump to MRU
			return e;
		}
		prev = e; e = e->next;
	}
	return NULL;
}
static void Lodor_artInsert(SDL_Surface* surf, const char* path) {
	LodorArtEntry* e = calloc(1, sizeof(LodorArtEntry));
	if (!e) { SDL_FreeSurface(surf); return; }
	e->surf = surf;
	e->bytes = (size_t)surf->h * (size_t)surf->pitch;
	strncpy(e->path, path, sizeof(e->path)-1);
	e->next = lodor_art_head; lodor_art_head = e;
	lodor_art_bytes += e->bytes;
	// evict LRU-first until under budget; never the just-inserted head, never the UI pin.
	while (lodor_art_bytes > lodor_art_budget) {
		LodorArtEntry* victim = NULL; LodorArtEntry* vprev = NULL;
		LodorArtEntry* it = lodor_art_head; LodorArtEntry* prev = NULL;
		while (it) { // last non-pinned, non-head entry = LRU victim
			if (it != lodor_art_head && strcmp(it->path, lodor_art_pin)!=0) { victim = it; vprev = prev; }
			prev = it; it = it->next;
		}
		if (!victim) break; // nothing evictable (pin + head alone over budget — tolerate)
		if (vprev) vprev->next = victim->next; else lodor_art_head = victim->next;
		lodor_art_bytes -= victim->bytes;
		SDL_FreeSurface(victim->surf);
		free(victim);
	}
}
// worker-side: fit a freshly-decoded surface to its display slot. Downscales anything
// bigger than the slot (aspect-preserving, fixed-point nearest walk — see note inside);
// with grow, integer-upscales small surfaces toward the slot via common/scaler.c
// (scaler_c16 — switcher previews are native-res screenshots). Scaling works on
// FIXED_DEPTH 565; a surface that needs no scaling is stored as decoded.
static SDL_Surface* Lodor_artFit(SDL_Surface* in, int max_w, int max_h, int grow) {
	if (!in || in->w<=0 || in->h<=0) return in;
	if (max_w<=0 || max_h<=0) return in;
	int tw = 0, th = 0;
	if (in->w > max_w || in->h > max_h) {
		// scale to fit, preserving aspect (integer math: pick the tighter axis)
		tw = max_w; th = (int)((long long)in->h * max_w / in->w);
		if (th > max_h) { th = max_h; tw = (int)((long long)in->w * max_h / in->h); }
		if (tw < 1) tw = 1;
		if (th < 1) th = 1;
	}
	else if (grow && in->w*2 <= max_w && in->h*2 <= max_h) {
		int k = max_w / in->w;
		int ky = max_h / in->h;
		if (ky < k) k = ky;
		if (k > 6) k = 6; // scaler.c integer scalers top out at 6x
		if (k >= 2) { tw = in->w * k; th = in->h * k; }
	}
	if (!tw) return in; // already fits — keep as decoded
	SDL_Surface* conv = SDL_CreateRGBSurface(SDL_SWSURFACE, in->w, in->h, FIXED_DEPTH, RGBA_MASK_565);
	SDL_Surface* out  = SDL_CreateRGBSurface(SDL_SWSURFACE, tw, th, FIXED_DEPTH, RGBA_MASK_565);
	if (!conv || !out) {
		if (conv) SDL_FreeSurface(conv);
		if (out) SDL_FreeSurface(out);
		return in; // can't scale — store as decoded (blit clips like it always did)
	}
	SDL_BlitSurface(in, NULL, conv, NULL); // format conversion (worker-local surfaces only)
	if (tw > in->w) { // integer upscale — common/scaler.c
		scaler_c16(tw/in->w, th/in->h, conv->pixels, out->pixels,
			in->w, in->h, conv->pitch, tw, th, out->pitch);
	}
	else {
		// arbitrary-ratio downscale: 16.16 fixed-point nearest-neighbor walk (the same
		// idiom minarch's Menu_scale uses). common/scaler.c only ships integer UPscalers,
		// and the AA scaler in api.c is ARM32 inline asm (__ARM_ARCH>=5 also matches
		// aarch64 and mis-assembles there) — so the rare out-of-spec downscale keeps a
		// small local loop. Quality is fine: this path only fires on oversized assets.
		uint16_t* lodor_sp = (uint16_t*)conv->pixels;
		uint16_t* lodor_dp = (uint16_t*)out->pixels;
		uint32_t lodor_mx = ((uint32_t)in->w << 16) / (uint32_t)tw;
		uint32_t lodor_my = ((uint32_t)in->h << 16) / (uint32_t)th;
		uint32_t lodor_sy = 0;
		for (int y=0; y<th; y++) {
			uint16_t* lodor_srow = lodor_sp + (lodor_sy>>16) * (uint32_t)(conv->pitch/2);
			uint16_t* lodor_drow = lodor_dp + (uint32_t)y * (uint32_t)(out->pitch/2);
			uint32_t lodor_sx = 0;
			for (int x=0; x<tw; x++) { lodor_drow[x] = lodor_srow[lodor_sx>>16]; lodor_sx += lodor_mx; }
			lodor_sy += lodor_my;
		}
	}
	SDL_FreeSurface(conv);
	SDL_FreeSurface(in);
	return out;
}
static int Lodor_artWorker(void* unused) {
	(void)unused;
	for (;;) {
		SDL_LockMutex(lodor_art_mutex);
		LodorArtReq req; req.path[0] = '\0';
		while (!lodor_art_shutdown) {
			for (int i=0; i<LODOR_ART_QUEUE; i++) { // current slot first, then prefetch
				if (lodor_art_queue[i].path[0]) { req = lodor_art_queue[i]; lodor_art_queue[i].path[0]='\0'; break; }
			}
			if (req.path[0]) break;
			SDL_CondWait(lodor_art_cond, lodor_art_mutex);
		}
		if (lodor_art_shutdown) { SDL_UnlockMutex(lodor_art_mutex); break; }
		SDL_UnlockMutex(lodor_art_mutex);

		SDL_Surface* img = exists(req.path) ? IMG_Load(req.path) : NULL; // the expensive decode, off-UI
		if (img) img = Lodor_artFit(img, req.max_w, req.max_h, req.grow); // downscale/grow-on-insert

		SDL_LockMutex(lodor_art_mutex);
		if (img) {
			// stale-drop by sequence: a current-slot decode that was superseded while in
			// flight is discarded, never inserted (the newer request is already queued).
			if (req.seq >= 0 && req.seq != lodor_art_seq) {
				SDL_FreeSurface(img);
			}
			else if (Lodor_artFind(req.path)) {
				SDL_FreeSurface(img); // raced a duplicate — cache already has it
			}
			else {
				Lodor_artInsert(img, req.path);
				lodor_art_ready = 1;
			}
		}
		SDL_UnlockMutex(lodor_art_mutex);
	}
	return 0;
}
static void Lodor_artInit(void) {
	// byte budget: 4MB on the 128MB miyoomini, 8MB everywhere else. Runtime branch —
	// PLATFORM is a string literal macro, so this is a one-shot strcmp, no new ifdefs.
	lodor_art_budget = (strcmp(PLATFORM, "miyoomini")==0) ? LODOR_ART_BUDGET_MIYOOMINI : LODOR_ART_BUDGET_DEFAULT;
	memset(lodor_art_queue, 0, sizeof(lodor_art_queue));
	lodor_art_mutex = SDL_CreateMutex();
	lodor_art_cond  = SDL_CreateCond();
	if (lodor_art_mutex && lodor_art_cond)
		// SDL2 added a thread name arg (SDL_CreateThread(fn,name,data)); SDL 1.2 is (fn,data).
		// USE_SDL2 is defined by the SDL2 platforms makefiles; miyoomini (USE_SDL) keeps the 2-arg form.
#ifdef USE_SDL2
		lodor_art_thread = SDL_CreateThread(Lodor_artWorker, "lodor-art", NULL);
#else
		lodor_art_thread = SDL_CreateThread(Lodor_artWorker, NULL);
#endif
}
static void Lodor_artQuit(void) {
	if (!lodor_art_mutex) return;
	SDL_LockMutex(lodor_art_mutex);
	lodor_art_shutdown = 1;
	if (lodor_art_cond) SDL_CondSignal(lodor_art_cond);
	SDL_UnlockMutex(lodor_art_mutex);
	if (lodor_art_thread) SDL_WaitThread(lodor_art_thread, NULL);
	while (lodor_art_head) {
		LodorArtEntry* e = lodor_art_head;
		lodor_art_head = e->next;
		SDL_FreeSurface(e->surf);
		free(e);
	}
	lodor_art_bytes = 0;
	if (lodor_art_cond)  SDL_DestroyCond(lodor_art_cond);
	if (lodor_art_mutex) SDL_DestroyMutex(lodor_art_mutex);
	lodor_art_thread = NULL; lodor_art_cond = NULL; lodor_art_mutex = NULL;
}
// Request async load of `path` for a max_w x max_h display slot. Returns the cached surface
// NOW on a hit (bumped to MRU and pinned against eviction until the next request, so the
// pointer is safe to blit this frame), else NULL and queues the decode as the CURRENT
// request (slot 0, sequence-stamped — a newer current request stale-drops this one).
static SDL_Surface* Lodor_artRequest(const char* path, int max_w, int max_h, int grow) {
	if (!lodor_art_mutex || !path || !path[0]) return NULL;
	SDL_Surface* ready = NULL;
	SDL_LockMutex(lodor_art_mutex);
	LodorArtEntry* e = Lodor_artFind(path);
	if (e) {
		ready = e->surf;
		strncpy(lodor_art_pin, path, sizeof(lodor_art_pin)-1); // eviction-proof while the UI holds it
	}
	else if (strcmp(lodor_art_queue[0].path, path)!=0) {
		lodor_art_seq++;
		strncpy(lodor_art_queue[0].path, path, MAX_PATH-1); lodor_art_queue[0].path[MAX_PATH-1]='\0';
		lodor_art_queue[0].max_w = max_w; lodor_art_queue[0].max_h = max_h;
		lodor_art_queue[0].grow = grow; lodor_art_queue[0].seq = lodor_art_seq;
		if (lodor_art_cond) SDL_CondSignal(lodor_art_cond);
	}
	SDL_UnlockMutex(lodor_art_mutex);
	return ready;
}
// Queue a low-priority prefetch (selected +/- 1). Never returns a surface, never bumps the
// sequence (seq -1 = not stale-droppable), drops silently when both prefetch slots are busy
// — the queue stays bounded at current + 2.
static void Lodor_artPrefetch(const char* path, int max_w, int max_h, int grow) {
	if (!lodor_art_mutex || !path || !path[0]) return;
	SDL_LockMutex(lodor_art_mutex);
	if (!Lodor_artFind(path) && strcmp(lodor_art_queue[0].path, path)!=0) {
		int have = 0;
		for (int i=1; i<LODOR_ART_QUEUE; i++) if (strcmp(lodor_art_queue[i].path, path)==0) have = 1;
		if (!have) for (int i=1; i<LODOR_ART_QUEUE; i++) {
			if (!lodor_art_queue[i].path[0]) {
				strncpy(lodor_art_queue[i].path, path, MAX_PATH-1); lodor_art_queue[i].path[MAX_PATH-1]='\0';
				lodor_art_queue[i].max_w = max_w; lodor_art_queue[i].max_h = max_h;
				lodor_art_queue[i].grow = grow; lodor_art_queue[i].seq = -1;
				if (lodor_art_cond) SDL_CondSignal(lodor_art_cond);
				break;
			}
		}
	}
	SDL_UnlockMutex(lodor_art_mutex);
}
// Poll-and-clear: returns 1 once when a freshly-decoded surface arrives (caller forces repaint).
static int Lodor_artPollReady(void) {
	if (!lodor_art_mutex) return 0;
	int r;
	SDL_LockMutex(lodor_art_mutex);
	r = lodor_art_ready; lodor_art_ready = 0;
	SDL_UnlockMutex(lodor_art_mutex);
	return r;
}

// lodor §11 (box art): if the highlighted/opened ROM has a saved cover, load it and
// blit it CENTERED in the upper safe area of the screen, returning the y at which the
// art's bottom sits (so the caller can place text below it). Returns 0 when there is no
// cover OR the cover is still decoding (caller renders text full-screen as before — graceful,
// never crashes). §artcache: the decode happens on the worker thread; this returns 0 until the
// cover is ready, then blits the cached surface (cache-owned — NOT freed here).
static int Lodor_drawBoxArt(SDL_Surface* screen, const char* rompath) {
	char media[MAX_PATH];
	if (!Lodor_mediaPath(rompath, media, sizeof(media))) return 0;
	if (!exists(media)) return 0;
	SDL_Surface* art = Lodor_artRequest(media, FIXED_HEIGHT, FIXED_HEIGHT, 0); // async: cached surface if ready, else NULL (load kicked)
	if (!art) return 0;

	int safe_w = screen->w - LODOR_OB_SAFE_SIDE*2;
	if (safe_w < SCALE1(40)) safe_w = SCALE1(40);

	// Center horizontally within the safe width; if the art is somehow wider than the
	// safe area, left-clip via SDL's blit (it clips to dst) rather than scaling here.
	int aw = art->w, ah = art->h;
	int ax = (screen->w - aw) / 2;
	if (ax < LODOR_OB_SAFE_SIDE) ax = LODOR_OB_SAFE_SIDE;
	int ay = LODOR_OB_SAFE_TOP;  // sit just below the status-bar row

	SDL_BlitSurface(art, NULL, screen, &(SDL_Rect){ ax, ay });
	int bottom = ay + ah;
	// §artcache: do NOT free — the surface is owned by the LRU cache (pinned this frame).
	return bottom;
}

// Render the welcome / intro step.
static void Lodor_obDrawWelcome(SDL_Surface* screen) {
	GFX_clear(screen);
	GFX_blitHardwareGroup(screen, 0);
	Lodor_obMessage(screen,
		"Welcome to LodorOS\n\nLet's connect this device to your RomM library.\n\nYou'll need your RomM server address and an 8-digit pair code from its web UI.");
	// B still silently backs out of onboarding (escape hatch in the input handler), but we no longer
	// advertise "Press B to skip" on-screen now that Wi-Fi is a proper first step.
	GFX_blitButtonGroup((char*[]){ "A","START", NULL }, 0, screen, 1);
	GFX_flip(screen);
}


// lodor: cached vertical "LodorOS" brand watermark (built once, reused, freed at quit).
static SDL_Surface* lodor_watermark = NULL; // rotated surface, NULL until first built
static int          lodor_watermark_tried = 0; // 1 once we've attempted a build (avoid retry on failure)
static void Lodor_freeWatermark(void) {
	if (lodor_watermark) { SDL_FreeSurface(lodor_watermark); lodor_watermark = NULL; }
}
// Render "LodorOS" horizontally, then rotate 90 deg clockwise into a vertical column
// reading top-to-bottom (first letter at top). SDL1.2 has no rotate primitive, so we
// transpose pixels by hand. TTF_RenderUTF8_Blended is 32bpp ARGB, so we copy Uint32s and
// keep per-pixel alpha intact. Returns the cached surface (may be NULL on failure).
static SDL_Surface* Lodor_getWatermark(void) {
	if (lodor_watermark || lodor_watermark_tried) return lodor_watermark;
	lodor_watermark_tried = 1;
	TTF_Font* wf = font.large; // 32px at FIXED_SCALE=2; "LodorOS" rotated height fits in 480/560
	if (!wf) return NULL;
	// two-tone brand: "Lodor" in cream + "OS" in red. Render each part separately, composite
	// horizontally (no gap), then the existing rotation below turns the flat strip vertical.
	SDL_Surface* p_lodor = TTF_RenderUTF8_Blended(wf, "Lodor", COLOR_WHITE);
	if (!p_lodor) return NULL;
	SDL_Surface* p_os = TTF_RenderUTF8_Blended(wf, "OS", COLOR_ACCENT);
	if (!p_os) { SDL_FreeSurface(p_lodor); return NULL; }
	// Blended text is always 32bpp; bail safely if some build returns otherwise.
	if (p_lodor->format->BytesPerPixel != 4 || p_os->format->BytesPerPixel != 4) {
		SDL_FreeSurface(p_lodor); SDL_FreeSurface(p_os); return NULL;
	}
	int cw = p_lodor->w + p_os->w;
	int chh = (p_lodor->h > p_os->h) ? p_lodor->h : p_os->h;
	SDL_Surface* flat = SDL_CreateRGBSurface(SDL_SWSURFACE, cw, chh, 32,
		p_lodor->format->Rmask, p_lodor->format->Gmask, p_lodor->format->Bmask, p_lodor->format->Amask);
	if (!flat) { SDL_FreeSurface(p_lodor); SDL_FreeSurface(p_os); return NULL; }
	// Composite by RAW PIXEL COPY, not SDL_BlitSurface: in SDL 1.2 an SDL_SRCALPHA blit alpha-BLENDS
	// over the destination and zeroes/corrupts the dest alpha, which left the rotated strip fully
	// transparent (the "watermark disappeared" bug). Copying the 32bpp RGBA pixels directly preserves
	// the text's per-pixel alpha exactly. All three surfaces are 32bpp from the same TTF render.
	SDL_FillRect(flat, NULL, 0);
	SDLX_SetAlpha(flat, SDL_SRCALPHA, 0);
	if (SDL_MUSTLOCK(flat))    SDL_LockSurface(flat);
	if (SDL_MUSTLOCK(p_lodor)) SDL_LockSurface(p_lodor);
	if (SDL_MUSTLOCK(p_os))    SDL_LockSurface(p_os);
	for (int y=0; y<p_lodor->h; y++) {
		Uint32* sp = (Uint32*)((Uint8*)p_lodor->pixels + y*p_lodor->pitch);
		Uint32* dp = (Uint32*)((Uint8*)flat->pixels + y*flat->pitch);
		for (int x=0; x<p_lodor->w; x++) dp[x] = sp[x];
	}
	for (int y=0; y<p_os->h; y++) {
		Uint32* sp = (Uint32*)((Uint8*)p_os->pixels + y*p_os->pitch);
		Uint32* dp = (Uint32*)((Uint8*)flat->pixels + y*flat->pitch) + p_lodor->w;
		for (int x=0; x<p_os->w; x++) dp[x] = sp[x];
	}
	if (SDL_MUSTLOCK(p_os))    SDL_UnlockSurface(p_os);
	if (SDL_MUSTLOCK(p_lodor)) SDL_UnlockSurface(p_lodor);
	if (SDL_MUSTLOCK(flat))    SDL_UnlockSurface(flat);
	SDL_FreeSurface(p_lodor); SDL_FreeSurface(p_os);
	int sw = flat->w, sh = flat->h;
	SDL_Surface* rot = SDL_CreateRGBSurface(SDL_SWSURFACE, sh, sw, 32,
		flat->format->Rmask, flat->format->Gmask, flat->format->Bmask, flat->format->Amask);
	if (!rot) { SDL_FreeSurface(flat); return NULL; }
	SDLX_SetAlpha(rot, SDL_SRCALPHA, 0); // preserve per-pixel alpha on later blit
	if (SDL_MUSTLOCK(flat)) SDL_LockSurface(flat);
	if (SDL_MUSTLOCK(rot))  SDL_LockSurface(rot);
	Uint8* sp = (Uint8*)flat->pixels;
	Uint8* dp = (Uint8*)rot->pixels;
	// 90 deg CW: dst(col=x, row=y) = src(col=y, row=sh-1-x). First letter lands at top.
	for (int y = 0; y < rot->h; y++) {            // rot->h == sw
		Uint32* drow = (Uint32*)(dp + y * rot->pitch);
		for (int x = 0; x < rot->w; x++) {        // rot->w == sh
			int sx = y;            // src column = dst row
			int sy = sh - 1 - x;   // src row    = sh-1 - dst col
			Uint32* spix = (Uint32*)(sp + sy * flat->pitch + sx * 4);
			drow[x] = *spix;
		}
	}
	if (SDL_MUSTLOCK(rot))  SDL_UnlockSurface(rot);
	if (SDL_MUSTLOCK(flat)) SDL_UnlockSurface(flat);
	SDL_FreeSurface(flat);
	lodor_watermark = rot;
	return lodor_watermark;
}

// shell-safe single-quote escape into a fixed buffer; returns out
static char* Lodor_shq(const char* in, char* out, int cap) {
	int o=0;
	for (int i=0; in[i] && o<cap-5; i++) {
		if (in[i]=='\'') { // ' -> '\''
			out[o++]='\''; out[o++]='\\'; out[o++]='\''; out[o++]='\'';
		} else out[o++]=in[i];
	}
	out[o]='\0';
	return out;
}

// blocking on-screen message (clear + centered text + flip) for the duration of a system() call.
// §3: inset horizontally to the safe side margin so a wide line never clips at the panel edge
// (these blocking screens are also used by the onboarding error/prompt flow).
static void Lodor_drawMessage(SDL_Surface* screen, char* msg) {
	GFX_clear(screen);
	GFX_blitHardwareGroup(screen, 0);
	GFX_blitMessage(font.large, msg, screen,
		&(SDL_Rect){ LODOR_OB_SAFE_SIDE, 0, screen->w - LODOR_OB_SAFE_SIDE*2, screen->h });
	GFX_flip(screen);
}

// lodor: live progress overlay that replaces a blocking system() call. Backgrounds shellcmd
// with a done-wrapper, then polls /tmp files (romm-phase, dl-progress, romm-done) ~16fps and
// renders a phase string + progress bar. B/MENU = soft-cancel (loop breaks, op finishes on its
// own; a transfer is never torn). Two hard exits: /tmp/romm-done exists, or a ~300s wall cap.
// Returns the contents of /tmp/romm-out (caller parses RESULT) in out_buf.
// lodor: fwd decl -- defined below, used by the WiFi-reset gate in Lodor_runWithProgress.
static int Lodor_inlineConfirm(SDL_Surface* screen, char* msg);
static void Lodor_runWithProgress(SDL_Surface* screen, const char* label, const char* shellcmd,
                                  char* out_buf, int out_cap) {
	if (out_buf && out_cap>0) out_buf[0]='\0';

	// lodor: at most two attempts of the SAME shellcmd. A WiFi-plausible failure on the
	// first attempt may offer a one-shot USB radio re-enumeration (8188fu devices only),
	// then retry once. Everything else (progress bar, 300s cap, soft-cancel) is per attempt.
	int lodor_offered = 0;
	for (int lodor_attempt = 0; lodor_attempt < 2; lodor_attempt++) {

	// Also clear the cover-cancel sentinel (#26): a leftover from a previous run's
	// B-press must never pre-cancel this run's box-art fetch. The engine clears it too,
	// belt-and-suspenders.
	system("rm -f /tmp/romm-done /tmp/romm-phase /tmp/dl-progress /tmp/romm-wifi-fail /tmp/lodor-cover-cancel 2>/dev/null");

	char cmd[MAX_PATH*4];
	snprintf(cmd, sizeof(cmd),
		"( %s > /tmp/romm-out 2>&1 ; echo $? > /tmp/romm-done ) &", shellcmd);
	system(cmd);

	const int MAX_FRAMES = 16 * 300; // ~300s wall cap at ~16fps
	int frame = 0;
	int cancelling = 0;

	for (; frame < MAX_FRAMES; frame++) {
		if (access("/tmp/romm-done", F_OK)==0) break; // completion exit

		PAD_poll();
		if (!cancelling && (PAD_justPressed(BTN_B) || PAD_justPressed(BTN_MENU))) {
			cancelling = 1; // soft-cancel: stop here, but DO NOT kill the bg op
			// #26: touch the cover-cancel sentinel so the engine's box-art fetch loop
			// aborts the in-flight cover and skips the rest — otherwise "Cancelling..."
			// hangs until the current cover's slow-radio download times out. The stub /
			// index / save / state work is unaffected; only the cosmetic cover pass reads
			// this file. Best-effort touch; the engine polls it between covers.
			system("touch /tmp/lodor-cover-cancel 2>/dev/null");
		}

		char phase[256];
		phase[0]='\0';
		FILE* pf = fopen("/tmp/romm-phase", "r");
		if (pf) {
			if (fgets(phase, sizeof(phase), pf)) {
				char* nl = strpbrk(phase, "\r\n"); if (nl) *nl='\0';
			}
			fclose(pf);
		}
		if (phase[0]=='\0') {
			strncpy(phase, label ? label : "Working...", sizeof(phase)-1);
			phase[sizeof(phase)-1]='\0';
		}
		if (cancelling) {
			strncpy(phase, "Cancelling...", sizeof(phase)-1);
			phase[sizeof(phase)-1]='\0';
		}

		int pct = -1;
		FILE* df = fopen("/tmp/dl-progress", "r");
		if (df) {
			char pl[32]; if (fgets(pl, sizeof(pl), df)) {
				char* nl = strpbrk(pl, "\r\n"); if (nl) *nl='\0';
				if (pl[0]) {
					int v = atoi(pl);
					if (v < 0) pct = -1;
					else { if (v>100) v=100; pct = v; }
				}
			}
			fclose(df);
		}

		GFX_clear(screen);
		GFX_blitHardwareGroup(screen, 0);
		// §3: honest status lines can be long (e.g. "Connected to <SSID> but no IP - resetting
		// radio..."). Wrap to the safe width so the line folds instead of clipping at the panel edge,
		// then center within the safe-side box above the progress bar.
		GFX_wrapText(font.large, phase, screen->w - LODOR_OB_SAFE_SIDE*2, 4);
		GFX_blitMessage(font.large, phase, screen,
			&(SDL_Rect){ LODOR_OB_SAFE_SIDE, 0, screen->w - LODOR_OB_SAFE_SIDE*2, screen->h - SCALE1(PILL_SIZE*2)});

		int bw = screen->w - SCALE1(PADDING*4);
		int bh = SCALE1(PILL_SIZE/2);
		int bx = (screen->w - bw) / 2;
		int by = screen->h - SCALE1(PADDING*2 + PILL_SIZE);
		int t = SCALE1(2); if (t<1) t=1;
		SDL_FillRect(screen, &(SDL_Rect){bx,        by,        bw, t},  RGB_ACCENT);
		SDL_FillRect(screen, &(SDL_Rect){bx,        by+bh-t,   bw, t},  RGB_ACCENT);
		SDL_FillRect(screen, &(SDL_Rect){bx,        by,        t,  bh}, RGB_ACCENT);
		SDL_FillRect(screen, &(SDL_Rect){bx+bw-t,   by,        t,  bh}, RGB_ACCENT);
		int ix = bx + t*2;
		int iy = by + t*2;
		int iw = bw - t*4;
		int ih = bh - t*4;
		if (iw < 1) iw = 1; if (ih < 1) ih = 1;
		if (pct >= 0) {
			int fw = (int)((long)iw * pct / 100);
			if (fw > 0) SDL_FillRect(screen, &(SDL_Rect){ix, iy, fw, ih}, RGB_ACCENT);
		} else {
			int sw = iw / 5; if (sw < SCALE1(8)) sw = SCALE1(8); if (sw > iw) sw = iw;
			int span = iw - sw; if (span < 1) span = 1;
			int p = (frame * SCALE1(6)) % (span * 2);
			if (p > span) p = span*2 - p; // ping-pong
			SDL_FillRect(screen, &(SDL_Rect){ix + p, iy, sw, ih}, RGB_ACCENT);
		}

		GFX_flip(screen);
		SDL_Delay(60); // ~16fps
	}

	if (out_buf && out_cap>0) {
		FILE* of = fopen("/tmp/romm-out", "r");
		if (of) {
			size_t n = fread(out_buf, 1, out_cap-1, of);
			out_buf[n] = '\0';
			fclose(of);
		}
	}

		// lodor: WiFi-reset gate. romm-run wrote /tmp/romm-wifi-fail ('1' = WiFi-plausible
		// failure, '0'/absent = clean success or a non-WiFi failure like a 404). Only offer
		// the reset on the FIRST attempt, on 8188fu devices (.wifi-8188fu marker present),
		// and only once. On accept: re-enumerate the radio (~10s) and retry the SAME cmd.
		int lodor_wifi_fail = 0;
		{
			FILE* wf = fopen("/tmp/romm-wifi-fail", "r");
			if (wf) { int c = fgetc(wf); lodor_wifi_fail = (c=='1'); fclose(wf); }
		}
		if (lodor_wifi_fail && lodor_attempt==0 && !lodor_offered) {
			char lodor_mk[MAX_PATH];
			snprintf(lodor_mk, sizeof(lodor_mk), "%s/Tools/%s/Lodor.pak/.wifi-8188fu", SDCARD_PATH, PLATFORM);
			if (access(lodor_mk, F_OK)==0) {
				lodor_offered = 1;
				if (Lodor_inlineConfirm(screen,
					"This looks like a WiFi hiccup --\ncommon on this device.\n\nTry a WiFi reset?\n\nA: Reset   B: No")) {
					Lodor_drawMessage(screen, "Resetting WiFi...");
					char lodor_wrcmd[MAX_PATH+64];
					snprintf(lodor_wrcmd, sizeof(lodor_wrcmd),
						"'%s/Tools/%s/Lodor.pak/bin/wifi-reset' >/dev/null 2>&1", SDCARD_PATH, PLATFORM);
					system(lodor_wrcmd);
					continue; // second attempt: re-run the SAME shellcmd
				}
			}
		}
		break; // no gate / declined / second attempt: this result is final
	}
	// lodor: keep the screen awake for 15s after any task finishes. A long download runs
	// with no PAD input, so the autosleep idle timer is already past SLEEP_DELAY on return
	// and would blank the panel instantly. The main-loop autosleep gate honors this window.
	lodor_keepawake_until = SDL_GetTicks() + 15000;
}

// §2 [#38]: run a Wi-Fi scan via the shell (romm-run --wifi-scan prints one "<FLAG>\t<SSID>" line per
// network — FLAG = SECURED/OPEN, from the vendored wpa_cli scan) and build the native SSID picker list.
// Blocking "Scanning..." message during the scan (it needs the radio on + a wpa_cli scan, a few sec).
// SCAN-SPAM GUARD: this is the ONLY thing that runs a scan, and it is called ONLY on explicit user
// actions — entering the Wi-Fi step (A from Welcome) and an explicit rescan (Y). It is NEVER called
// from the per-frame render/poll path, so the scan fires once per user action, not dozens/sec.
// Reuses Entry/Array + the list draw; no driver reimplementation.
static void Lodor_obWifiScan(SDL_Surface* screen) {
	Lodor_freeWifiList();
	lodor_ob_wifi_list = Array_new();
	lodor_ob_wifi_sel = 0; lodor_ob_wifi_start = 0; lodor_ob_wifi_end = 0;

	Lodor_drawMessage(screen, "Scanning for Wi-Fi networks...");
	char cmd[MAX_PATH*2];
	snprintf(cmd, sizeof(cmd),
		"'%s%s' --wifi-scan > /tmp/lodor-wifi-scan.txt 2>/dev/null",
		SDCARD_PATH, LODOR_ROMM_BIN);
	system(cmd);

	FILE* f = fopen("/tmp/lodor-wifi-scan.txt", "r");
	if (f) {
		char line[256];
		while (fgets(line, sizeof(line), f)) {
			char* nl = strpbrk(line, "\r\n"); if (nl) *nl='\0';
			// Each line is "<FLAG>\t<SSID>" where FLAG is SECURED or OPEN (romm-run --wifi-scan).
			// HONEST DEFAULT: if a line lacks a recognizable flag, treat it as SECURED (prompt) so we
			// never attempt an open-connect against a network whose security we couldn't determine.
			int secured = 1;            // default secured-on-unknown
			char* ssid = line;
			char* tab = strchr(line, '\t');
			if (tab) {
				*tab = '\0';
				char* flag = line;      // text before the TAB
				ssid = tab + 1;         // SSID after the TAB
				if (strcmp(flag, "OPEN")==0) secured = 0;
				else secured = 1;       // "SECURED" or anything unexpected -> secured
			}
			// trim the SSID field
			char* s = ssid; while (*s==' '||*s=='\t') s++;
			int n = strlen(s); while (n>0 && (s[n-1]==' '||s[n-1]=='\t')) s[--n]='\0';
			if (s[0]=='\0') continue;
			Entry* e = Entry_new("", ENTRY_ROM);
			// Display name: prefix a small lock on secured networks (nice-to-have indicator).
			char disp[LODOR_OB_WIFI_SSID_MAX + 8];
			snprintf(disp, sizeof(disp), "%s%s", secured ? "* " : "  ", s);
			free(e->name); e->name = strdup(disp);
			free(e->path); e->path = strdup(s);                       // raw SSID for --wifi-connect
			e->unique = strdup(secured ? "SECURED" : "OPEN");         // security flag carrier
			Array_push(lodor_ob_wifi_list, e);
		}
		fclose(f);
	}
	// initialize the scroll/paging window over the (possibly long) network list.
	{
		int wc = lodor_ob_wifi_list ? lodor_ob_wifi_list->count : 0;
		lodor_ob_wifi_start = 0;
		lodor_ob_wifi_end = (wc < (MAIN_ROW_COUNT-1)) ? wc : (MAIN_ROW_COUNT-1);
	}
}

// §2 [#38]: connect to the chosen network through the §1 HONEST path. romm-run --wifi-connect saves
// the creds, regenerates the wpa config, and brings Wi-Fi up via wifi_acquire — which writes the
// verified verbose status (Powering radio / Connecting to <SSID> / Associated / Got IP / Wi-Fi
// connected) to /tmp/romm-phase, displayed VERBATIM by the progress overlay. Fix 2: "online=1" now
// means a USABLE Wi-Fi LINK (up + IP), DECOUPLED from RomM reachability — wifi_acquire no longer tears
// down a working link when the server is unreachable. So success here just means "Wi-Fi is up";
// whether RomM is reachable is verified at the NEXT (Server) step via --validate, which reports the
// honest "couldn't reach your server" without killing Wi-Fi. Returns 1 on a Wi-Fi-connected link
// ("RESULT online=1"); on failure the honest reason wifi_acquire left in /tmp/romm-phase is the last
// thing shown, and we report a clear failure so the user can retry or pick another network.
static int Lodor_obWifiConnect(SDL_Surface* screen, const char* ssid, const char* psk) {
	char qs[LODOR_OB_WIFI_SSID_MAX*4], qp[LODOR_OB_WIFI_PSK_MAX*4];
	Lodor_shq(ssid, qs, sizeof(qs));
	Lodor_shq(psk ? psk : "", qp, sizeof(qp));
	char cmd[MAX_PATH*3], out[512];
	if (psk && psk[0])
		snprintf(cmd, sizeof(cmd), "'%s%s' --wifi-connect '%s' '%s'", SDCARD_PATH, LODOR_ROMM_BIN, qs, qp);
	else
		snprintf(cmd, sizeof(cmd), "'%s%s' --wifi-connect '%s'", SDCARD_PATH, LODOR_ROMM_BIN, qs);
	char label[96]; snprintf(label, sizeof(label), "Connecting to %s...", ssid);
	Lodor_runWithProgress(screen, label, cmd, out, sizeof(out));
	int online = 0;
	{ char* r = strstr(out, "online="); if (r) online = atoi(r+7); }
	return online;
}

// append a queue entry (SDCARD-relative, matching how Collections store paths)
static void Lodor_queueDownload(const char* rompath) {
	const char* rel = rompath;
	int pl = strlen(SDCARD_PATH);
	if (strncmp(rompath, SDCARD_PATH, pl)==0) {
		rel = rompath + pl;
		if (*rel=='/') rel++; // strip leading slash for a clean relative path
	}
	FILE* qf = fopen(LODOR_QUEUE_FILE, "a");
	if (qf) { fprintf(qf, "%s\n", rel); fclose(qf); }
}

// ── FIX 3: per-system performance tier marker ──────────────────────────────────────
// A small colored dot next to each shipped system row in the ROOT menu, mapped from the
// Retro Handhelds sheet grade baked per-platform into system-tiers.conf (lines TAG=tier,
// '#' comments allowed). tier ∈ {great,good,ok,rough}; F-graded systems are never shipped
// so never appear. The conf is keyed by the MinUI folder TAG (the trailing "(TAG)" of the
// Roms folder name, verified on-card: PS/FC/SFC/MD/GB/GBA/GBC…). Unknown/unmapped folders
// render NO mark — never a wrong one.
#define LODOR_TIERS_FILE SDCARD_PATH "/Tools/" PLATFORM "/Lodor.pak/system-tiers.conf"
typedef struct { char tag[24]; int tier; } LodorTier; // tier 0=great 1=good 2=ok 3=rough
static LodorTier lodor_tiers[64];
static int lodor_tiers_n = -1; // -1 = not yet loaded from disk

static int Lodor_tierFromWord(const char* w) {
	if (!strcasecmp(w,"great")) return 0;
	if (!strcasecmp(w,"good"))  return 1;
	if (!strcasecmp(w,"ok"))    return 2;
	if (!strcasecmp(w,"rough")) return 3;
	return -1;
}
static void Lodor_loadTiers(void) {
	lodor_tiers_n = 0;
	FILE* f = fopen(LODOR_TIERS_FILE, "r");
	if (!f) return;
	char line[128];
	while (fgets(line, sizeof(line), f) && lodor_tiers_n < 64) {
		char* s = line; while (*s==' '||*s=='\t') s++;
		if (*s=='#' || *s=='\0' || *s=='\n' || *s=='\r') continue;
		char* eq = strchr(s, '=');
		if (!eq) continue;
		*eq = '\0';
		char* key = s; char* val = eq+1;
		int kl = strlen(key); while (kl>0 && (key[kl-1]==' '||key[kl-1]=='\t')) key[--kl]='\0';
		while (*val==' '||*val=='\t') val++;
		char* ve = val; while (*ve && *ve!=' ' && *ve!='\t' && *ve!='\r' && *ve!='\n') ve++; *ve='\0';
		int tier = Lodor_tierFromWord(val);
		if (key[0]=='\0' || tier<0) continue;
		strncpy(lodor_tiers[lodor_tiers_n].tag, key, sizeof(lodor_tiers[0].tag)-1);
		lodor_tiers[lodor_tiers_n].tag[sizeof(lodor_tiers[0].tag)-1]='\0';
		lodor_tiers[lodor_tiers_n].tier = tier;
		lodor_tiers_n++;
	}
	fclose(f);
}
// map a system folder path -> tier via its trailing "(TAG)"; -1 if none/unknown.
static int Lodor_tierForSystemPath(const char* path) {
	if (lodor_tiers_n < 0) Lodor_loadTiers();
	if (lodor_tiers_n == 0) return -1;
	const char* base = strrchr(path, '/'); base = base ? base+1 : path;
	const char* op = strrchr(base, '(');
	if (!op) return -1;
	const char* cp = strchr(op, ')');
	if (!cp || cp <= op+1) return -1;
	char tag[24]; int n = (int)(cp-(op+1));
	if (n >= (int)sizeof(tag)) n = sizeof(tag)-1;
	memcpy(tag, op+1, n); tag[n]='\0';
	for (int i=0;i<lodor_tiers_n;i++) if (!strcasecmp(lodor_tiers[i].tag, tag)) return lodor_tiers[i].tier;
	return -1;
}
// tier -> a subtle dot color, mapped to the screen's pixel format.
static Uint32 Lodor_tierColor(SDL_Surface* screen, int tier) {
	int r=0xA0,g=0xA0,b=0xA0;
	switch (tier) {
		case 0: r=0x6F; g=0xBF; b=0x4B; break; // great — green
		case 1: r=0x4F; g=0x9F; b=0xE0; break; // good  — blue
		case 2: r=0xE0; g=0xB0; b=0x40; break; // ok    — amber
		case 3: r=0xD0; g=0x5F; b=0x5F; break; // rough — muted red
	}
	return SDL_MapRGB(screen->format, r, g, b);
}

// count non-blank lines in download-queue.txt (the live "Download Queue (N)" badge).
static int Lodor_queueCount(void) {
	int n = 0;
	FILE* qf = fopen(LODOR_QUEUE_FILE, "r");
	if (qf) {
		char line[512];
		while (fgets(line, sizeof(line), qf)) {
			char* s = line;
			while (*s==' '||*s=='\t'||*s=='\r'||*s=='\n') s++;
			if (*s) n++;
		}
		fclose(qf);
	}
	return n;
}

// §override (#144): ".../<NAME>.pak/launch.sh" -> NAME (the pak stem shown in labels).
static void Lodor_pakStem(const char* pak_path, char* out, size_t n) {
	out[0] = '\0';
	char tmp[256];
	strncpy(tmp, pak_path, sizeof(tmp)-1); tmp[sizeof(tmp)-1]='\0';
	char* ls = strrchr(tmp, '/');           // strip /launch.sh
	if (!ls) return;
	*ls = '\0';
	char* pk = strrchr(tmp, '/');           // the <NAME>.pak component
	pk = pk ? pk+1 : tmp;
	char* dot = strrchr(pk, '.');
	if (dot && strcmp(dot, ".pak")==0) *dot = '\0';
	strncpy(out, pk, n-1); out[n-1] = '\0';
}
// §override (#144): write (pak set) or delete (pak NULL/"") the per-game sidecar.
// A hand-authored core= line survives a pak change; choosing the default deletes the
// whole sidecar (spec'd) — default means "no per-game state at all".
static void Lodor_writeEmuSidecar(const char* rom_path, const char* pakname) {
	char sc[MAX_PATH];
	Lodor_emuSidecarPath(rom_path, sc, sizeof(sc));
	if (!sc[0]) return;
	if (!pakname || !pakname[0]) { unlink(sc); return; }
	char core[256];
	Lodor_readEmuSidecar(rom_path, NULL, 0, core, sizeof(core));
	char dir[MAX_PATH]; // ensure .minui/<TAG>/ exists (no state may have been saved yet)
	strcpy(dir, sc);
	char* slash = strrchr(dir, '/');
	if (slash) { *slash = '\0'; mkdir(dir, 0755); }
	// §atomic (#161): build the full sidecar body, then temp+fsync+rename (see Lodor_atomicWrite).
	char body[512];
	int bn = snprintf(body, sizeof(body), "pak=%s\n", pakname);
	if (bn < 0 || (size_t)bn >= sizeof(body)) return;
	if (core[0]) {
		int cn = snprintf(body + bn, sizeof(body) - bn, "core=%s\n", core);
		if (cn < 0 || (size_t)cn >= sizeof(body) - bn) return;
		bn += cn;
	}
	Lodor_atomicWrite(sc, body, (size_t)bn);
}
// §override (#144): candidate paks for the ROM's folder TAG, by NAMING CONVENTION —
// <TAG>.pak (the default, always row 0) plus every <TAG>-<VARIANT>.pak found across BOTH
// pak roots (device root, then the system paks), deduped by stem. The current choice is
// marked in its label so the picker doubles as status.
static void Lodor_buildEmuPick(const char* rom_path) {
	Lodor_freeEmuPick();
	lodor_emupick_items = Array_new();
	lodor_emupick_sel = 0;

	char tag[MAX_PATH];
	Lodor_romTag(rom_path, tag);
	char cur_path[256], cur[128];
	Lodor_resolveEmu(rom_path, cur_path);
	Lodor_pakStem(cur_path, cur, sizeof(cur));

	#define LODOR_EPADD(stem, is_default) do { \
		int dup = 0; \
		for (int i=0; i<lodor_emupick_items->count; i++) { \
			Entry* ex = lodor_emupick_items->items[i]; \
			if (strcmp(ex->path, (is_default)?"":(stem))==0) { dup = 1; break; } \
		} \
		if (!dup) { \
			char lbl[192]; \
			snprintf(lbl, sizeof(lbl), "%s%s%s", (stem), (is_default)?" (default)":"", \
				strcmp((stem), cur)==0 ? "  \xE2\x97\x8F" : ""); /* current marker dot */ \
			Entry* e = Entry_new((char*)rom_path, ENTRY_ROM); /* Entry_new only reads it */ \
			free(e->name); e->name = strdup(lbl); \
			free(e->path); e->path = strdup((is_default)?"":(stem)); \
			Array_push(lodor_emupick_items, e); \
			if (strcmp((stem), cur)==0) lodor_emupick_sel = lodor_emupick_items->count-1; \
		} \
	} while(0)

	LODOR_EPADD(tag, 1); // default row first — even if the default pak is missing, "default" is a valid choice

	char roots[2][256];
	sprintf(roots[0], "%s/Emus/%s", SDCARD_PATH, PLATFORM);
	sprintf(roots[1], "%s/Emus", PAKS_PATH);
	char prefix[MAX_PATH];
	snprintf(prefix, sizeof(prefix), "%s-", tag);
	for (int r=0; r<2; r++) {
		DIR* dh = opendir(roots[r]);
		if (!dh) continue;
		struct dirent* dp;
		while ((dp = readdir(dh)) != NULL) {
			if (dp->d_name[0]=='.') continue;
			char* dot = strrchr(dp->d_name, '.');
			if (!dot || strcmp(dot, ".pak")!=0) continue;
			char stem[128];
			size_t sl = (size_t)(dot - dp->d_name);
			if (sl==0 || sl>=sizeof(stem)) continue;
			memcpy(stem, dp->d_name, sl); stem[sl]='\0';
			if (!prefixMatch(prefix, stem)) continue; // variants only (<TAG>-<VARIANT>)
			char ls[256];
			snprintf(ls, sizeof(ls), "%s/%s/launch.sh", roots[r], dp->d_name);
			if (!exists(ls)) continue;
			LODOR_EPADD(stem, 0);
		}
		closedir(dh);
	}
	#undef LODOR_EPADD
}
// lodor §gameswitch (#149): newest on-disk preview for a ROM — scans .minui/<TAG>/ for
// "<rom>.<anything>.bmp" (manual save-state shots + the new minarch <rom>.auto.bmp) and
// "<rom>.auto.png" (wrapper/RomM-pulled captures, contract), newest mtime wins. Both
// sides are marker-stripped so a stub-flip rename doesn't orphan a capture.
static void Lodor_newestShot(const char* sd_path, char* out, size_t outsz) {
	out[0] = '\0';
	char tag[MAX_PATH];
	Lodor_romTag(sd_path, tag);
	if (!tag[0]) return;
	const char* base = strrchr(sd_path, '/');
	base = base ? base+1 : sd_path;
	const char* canon = Lodor_stripMarker(base);
	size_t clen = strlen(canon);
	if (!clen) return;
	char dir[MAX_PATH];
	snprintf(dir, sizeof(dir), "%s/.minui/%s", SHARED_USERDATA_PATH, tag);
	DIR* dh = opendir(dir);
	if (!dh) return;
	struct dirent* dp;
	time_t best = 0;
	while ((dp = readdir(dh)) != NULL) {
		if (dp->d_name[0]=='.') continue;
		if (!suffixMatch(".bmp", dp->d_name) && !suffixMatch(".png", dp->d_name)) continue;
		if (suffixMatch(".png", dp->d_name) && !suffixMatch(".auto.png", dp->d_name)) continue;
		const char* dn = Lodor_stripMarker(dp->d_name);
		if (strncmp(dn, canon, clen)!=0 || dn[clen]!='.') continue;
		char full[MAX_PATH];
		int n = snprintf(full, sizeof(full), "%s/%s", dir, dp->d_name);
		if (n<=0 || n>=(int)sizeof(full)) continue;
		struct stat st;
		if (stat(full, &st)==0 && st.st_mtime >= best) {
			best = st.st_mtime;
			strncpy(out, full, outsz-1); out[outsz-1]='\0';
		}
	}
	closedir(dh);
}
// lodor §gameswitch (#149): playtime caption from the engine-owned totals.tsv (contract:
// $SDCARD/.userdata/shared/.lodor/playtime/totals.tsv — key \t rom_basename \t secs \t
// plays \t last_utc). Match by marker-stripped rom basename; degrade to no caption when
// the file is absent or the game has no row (Lane A produces the file — never required).
static void Lodor_playtimeCaption(const char* sd_path, char* out, size_t outsz) {
	out[0] = '\0';
	FILE* f = fopen(SHARED_USERDATA_PATH "/.lodor/playtime/totals.tsv", "r");
	if (!f) return;
	const char* base = strrchr(sd_path, '/');
	base = base ? base+1 : sd_path;
	const char* canon = Lodor_stripMarker(base);
	char line[1024];
	while (fgets(line, sizeof(line), f)) {
		char* t1 = strchr(line, '\t'); if (!t1) continue; *t1++ = '\0';
		char* t2 = strchr(t1, '\t');   if (!t2) continue; *t2++ = '\0';
		char* t3 = strchr(t2, '\t');   if (!t3) continue; *t3++ = '\0';
		// t1 = rom_basename, t2 = secs, t3 = "plays\tlast_utc"
		if (strcmp(Lodor_stripMarker(t1), canon)!=0) continue;
		long secs = atol(t2);
		long plays = atol(t3);
		if (secs < 60)            snprintf(out, outsz, "<1m played");
		else if (secs < 3600)     snprintf(out, outsz, "%ldm played", secs/60);
		else                      snprintf(out, outsz, "%ldh %ldm played", secs/3600, (secs%3600)/60);
		if (plays > 0) {
			size_t l = strlen(out);
			snprintf(out+l, outsz-l, " \xC2\xB7 %ld play%s", plays, plays==1?"":"s");
		}
		break;
	}
	fclose(f);
}
// lodor §gameswitch (#149): build the switcher model from the EXISTING recents Array —
// which the engine's --sync-continue already merges the RomM cross-device feed into
// (#37, capped at MAX_RECENTS) — top 8 available game entries.
static void Lodor_openSwitcher(void) {
	lodor_switch_count = 0;
	lodor_switch_sel = 0;
	if (!recents) return;
	for (int i=0; i<recents->count && lodor_switch_count<LODOR_SWITCH_MAX; i++) {
		Recent* r = recents->items[i];
		if (!r->available) continue;
		char sd_path[MAX_PATH];
		snprintf(sd_path, sizeof(sd_path), "%s%s", SDCARD_PATH, r->path);
		if (suffixMatch(".pak", sd_path)) continue; // games only
		int n = lodor_switch_count;
		strcpy(lodor_switch_path[n], sd_path);
		if (r->alias) { strncpy(lodor_switch_name[n], r->alias, 255); lodor_switch_name[n][255]='\0'; }
		else {
			char dn[MAX_PATH]; // getDisplayName wants MAX_PATH-sized buffers
			getDisplayName(sd_path, dn);
			strncpy(lodor_switch_name[n], dn, 255); lodor_switch_name[n][255]='\0';
		}
		Lodor_newestShot(sd_path, lodor_switch_shot[n], MAX_PATH);
		Lodor_playtimeCaption(sd_path, lodor_switch_cap[n], sizeof(lodor_switch_cap[n]));
		lodor_switch_count++;
	}
}
// build the context-aware action list for the selected ROM. Split (#144): the rebuild
// works from the lodor_rompath/lodor_on_device statics so the Emulator picker can refresh
// the row labels in place after a change.
static void Lodor_rebuildActions(void) {
	if (lodor_action_items) { EntryArray_free(lodor_action_items); lodor_action_items = NULL; }
	lodor_action_items = Array_new();

	// §override (#144): resolved emulator for the row label; flag a per-game override
	char lodor_emu_lbl[192];
	{
		char cur_path[256], cur[128], scpak[128];
		Lodor_resolveEmu(lodor_rompath, cur_path);
		Lodor_pakStem(cur_path, cur, sizeof(cur));
		Lodor_readEmuSidecar(lodor_rompath, scpak, sizeof(scpak), NULL, 0);
		int overridden = (scpak[0] && strcmp(scpak, cur)==0); // sidecar pak actually in effect
		snprintf(lodor_emu_lbl, sizeof(lodor_emu_lbl), "Emulator: %s%s", cur[0]?cur:"?", overridden?" (per-game)":"");
	}

	// each Entry: name overwritten with label, path with action id
	#define LODOR_ADD(label,id) do { \
		Entry* e = Entry_new(lodor_rompath, ENTRY_ROM); \
		free(e->name); e->name = strdup(label); \
		free(e->path); e->path = strdup(id); \
		Array_push(lodor_action_items, e); \
	} while(0)

	if (lodor_on_device) {
		LODOR_ADD("Play",        "play");
		LODOR_ADD("Sync save",   "syncsave");
		LODOR_ADD("Flashback",   "serversaves");
		LODOR_ADD(lodor_emu_lbl, "emupick");
		LODOR_ADD("Delete",      "delete");
		LODOR_ADD("Details",     "details");
	} else {
		LODOR_ADD("Play",        "play");
		LODOR_ADD("Download now","download");
		LODOR_ADD("Add to queue","queue");
		LODOR_ADD(lodor_emu_lbl, "emupick");
		LODOR_ADD("Details",     "details");
	}
	#undef LODOR_ADD
}
static void Lodor_openActions(Entry* sel) {
	Lodor_freeActions();
	lodor_action_sel = 0;

	strncpy(lodor_rompath, sel->path, MAX_PATH-1); lodor_rompath[MAX_PATH-1]='\0';
	strncpy(lodor_gamename, sel->name, 255); lodor_gamename[255]='\0';

	struct stat st;
	lodor_on_device = (stat(lodor_rompath, &st)==0 && st.st_size>0);
	lodor_filesize = (stat(lodor_rompath, &st)==0) ? (long)st.st_size : 0;

	Lodor_rebuildActions();
	lodor_show_actions = 1;
}

// lodor: render an absolute "YYYY-MM-DD HH:MM" save stamp as a short relative age for the Flashback
// timeline ("just now", "2h ago", "yesterday", "3d ago", "2w ago"). Returns 1 and fills out on
// success; returns 0 when the device clock is unset (year<2024 -> a relative age would be nonsense)
// or the stamp won't parse, so the caller falls back to showing the absolute date. No math.h.
static int Lodor_relTime(const char* stamp, char* out, size_t n) {
	if (!stamp || !*stamp) return 0;
	int Y,Mo,D,H,Mi;
	if (sscanf(stamp, "%d-%d-%d %d:%d", &Y,&Mo,&D,&H,&Mi) != 5) return 0;
	time_t now = time(NULL);
	struct tm* lt = localtime(&now);
	if (!lt || lt->tm_year + 1900 < 2024) return 0; // clock unset -> caller shows the date
	struct tm st; memset(&st, 0, sizeof(st));
	st.tm_year=Y-1900; st.tm_mon=Mo-1; st.tm_mday=D; st.tm_hour=H; st.tm_min=Mi; st.tm_isdst=-1;
	time_t se = mktime(&st);
	if (se == (time_t)-1) return 0;
	long d = (long)difftime(now, se);
	if (d < 0) d = 0;
	if      (d < 90)          snprintf(out, n, "just now");
	else if (d < 3600)        snprintf(out, n, "%ldm ago", d/60);
	else if (d < 86400)       snprintf(out, n, "%ldh ago", d/3600);
	else if (d < 2*86400)     snprintf(out, n, "yesterday");
	else if (d < 7*86400)     snprintf(out, n, "%ldd ago", d/86400);
	else if (d < 28*86400)    snprintf(out, n, "%ldw ago", d/(7*86400));
	else                      return 0; // older than a month -> show the absolute date
	return 1;
}

// lodor: per-game Flashback-timeline cache path (<pak>/.saves-cache/<sanitized rom path>.txt). The
// timeline lives on the server and changes rarely, so caching it makes opening Flashback INSTANT
// (cache-first; refresh in the background) AND lets you SEE your save points even when offline.
static void Lodor_savesCachePath(const char* rompath, char* out, size_t n) {
	char san[256]; size_t o=0;
	for (const char* p=rompath; *p && o<sizeof(san)-1; p++) {
		char c=*p; san[o++] = (c=='/'||c==' '||c=='\t'||c=='\''||c=='"') ? '_' : c;
	}
	san[o]='\0';
	if (o>200) { memmove(san, san+(o-200), 201); } // cap filename length, keep the distinctive tail
	snprintf(out, n, "%s/Tools/%s/Lodor.pak/.saves-cache/%s.txt", SDCARD_PATH, PLATFORM, san);
}

// parse /tmp/lodor-saves.txt (TAB: save_id \t date \t device \t sizeKB) into lodor_saves_items.
// Each row becomes one point on the Flashback timeline; the display label is "<when>  <device>"
// (when = relative age, or the absolute date when the clock is unset). The double-space delimiter
// is load-bearing: the restore-confirm handler splits the label back into when/device on it.
static void Lodor_buildSaves(void) {
	Lodor_freeSaves();
	lodor_saves_items = Array_new();
	lodor_saves_sel = 0;

	FILE* sf = fopen("/tmp/lodor-saves.txt", "r");
	if (sf) {
		char line[512];
		while (fgets(line, sizeof(line), sf)) {
			// strip trailing newline
			char* nl = strpbrk(line, "\r\n"); if (nl) *nl='\0';
			if (line[0]=='\0') continue;
			// split on tabs: id, date, device, size
			char* id = line;
			char* date = strchr(line, '\t');   if (!date) continue; *date++='\0';
			char* dev  = strchr(date, '\t');    if (dev)  *dev++='\0';  else dev="";
			char* size = dev[0] ? strchr(dev, '\t') : NULL; if (size) *size++='\0'; else size="";
			// Optional field 4 (engine EXTENDS the 0-3 contract, never reorders): "CURRENT" on the
			// single revision whose content matches the save currently on this device. The engine
			// only emits it when it can actually confirm the match (RomM content_hash vs local MD5),
			// so absence is honest "couldn't confirm", never "not current".
			char* mark = size[0] ? strchr(size, '\t') : NULL; if (mark) *mark++='\0'; else mark="";
			int is_current = (mark[0] && strcmp(mark, "CURRENT")==0);

			(void)size; // size dropped from the timeline row — when + who is the signal
			char rel[32], label[256];
			if (Lodor_relTime(date, rel, sizeof(rel)))
				snprintf(label, sizeof(label), "%s  %s", rel, dev[0]?dev:"-");
			else
				snprintf(label, sizeof(label), "%s  %s", date, dev[0]?dev:"-");
			// Mark the on-device revision. Appended with a leading double-space so it lands as an
			// IGNORED third segment for the restore-confirm splitter (when=field0, device=field1);
			// it never pollutes the device name shown in the flashback confirm. \xe2\x80\xa2 = bullet.
			if (is_current) {
				size_t l = strlen(label);
				snprintf(label + l, sizeof(label) - l, "  \xe2\x80\xa2 On device");
			}
			Entry* e = Entry_new(lodor_rompath, ENTRY_ROM);
			free(e->name); e->name = strdup(label);
			free(e->path); e->path = strdup(id); // keep the save_id in path
			Array_push(lodor_saves_items, e);
		}
		fclose(sf);
	}
}

// lodor: parse /tmp/lodor-feed.txt (TAB: game \t "YYYY-MM-DD HH:MM" \t device) into a
// read-only Sync Feed list. Rows: "<game> \xE2\x80\x94 <when>" + " \xC2\xB7 <device>" if present.
static void Lodor_buildFeed(void) {
	Lodor_freeFeed();
	lodor_feed_items = Array_new();
	lodor_feed_sel = 0;

	FILE* ff = fopen("/tmp/lodor-feed.txt", "r");
	if (ff) {
		char line[512];
		while (fgets(line, sizeof(line), ff)) {
			char* nl = strpbrk(line, "\r\n"); if (nl) *nl='\0';
			if (line[0]=='\0') continue;
			char* game = line;
			char* when = strchr(line, '\t'); if (!when) continue; *when++='\0';
			char* dev  = strchr(when, '\t');  if (dev) *dev++='\0'; else dev="";
			if (game[0]=='\0') continue;

			char label[384];
			if (dev[0])
				snprintf(label, sizeof(label), "%s \xE2\x80\x94 %s \xC2\xB7 %s", game, when, dev);
			else
				snprintf(label, sizeof(label), "%s \xE2\x80\x94 %s", game, when);
			Entry* e = Entry_new("", ENTRY_ROM);
			free(e->name); e->name = strdup(label);
			Array_push(lodor_feed_items, e);
		}
		fclose(ff);
	}
}

// lodor MULTI-USER (Switch User): build the user-picker list from the engine's
// --list-users — the RomM SERVER's actual users (GET /api/users via the admin token),
// NOT locally-typed profiles. Each non-empty line is the strict 4-field contract
//   <active>\t<username>\t<role>\t<signedin>
// (active/signedin EACH a single '0'/'1'; username non-empty; role is free display text).
// Rows:
//   active                -> "<username> (current)"
//   signed-in, not active -> "<username>"
//   not signed-in         -> "<username> - sign in"
// entry->path encodes the action: path[0] = the signedin flag ('0'/'1'), path+1 = the
// username. There is NO "+ Add Profile" row — you PICK an existing user, never type a name.
static void Lodor_buildProfiles(void) {
	Lodor_freeProfiles();
	lodor_profile_items = Array_new();

	char cmd[MAX_PATH*2];
	snprintf(cmd, sizeof(cmd), "'%s%s' --list-users > /tmp/lodor-users.txt 2>/dev/null", SDCARD_PATH, LODOR_ROMM_BIN);
	system(cmd);

	FILE* pf = fopen("/tmp/lodor-users.txt", "r");
	if (pf) {
		char line[256];
		while (fgets(line, sizeof(line), pf)) {
			char* nl = strpbrk(line, "\r\n"); if (nl) *nl='\0';
			if (line[0]=='\0') continue;
			// STRICT parse of <active>\t<username>\t<role>\t<signedin>. Reject anything
			// else (CLI usage/error text, blank lines, wrong field count) so stray engine
			// output can never render as a bogus user row.
			char* active = line;
			char* uname  = strchr(active, '\t'); if (!uname)  continue; *uname++  = '\0';
			char* role   = strchr(uname,  '\t'); if (!role)   continue; *role++   = '\0';
			char* signd  = strchr(role,   '\t'); if (!signd)  continue; *signd++  = '\0';
			if (strchr(signd, '\t')) continue;                                  // too many fields
			if (!((active[0]=='0'||active[0]=='1') && active[1]=='\0')) continue; // active 0/1
			if (!((signd[0]=='0'||signd[0]=='1')  && signd[1]=='\0'))  continue;  // signedin 0/1
			if (uname[0]=='\0') continue;                                        // username required
			(void)role; // role is for future display; selection keys off signedin+username
			char disp[200];
			if (active[0]=='1')       snprintf(disp, sizeof(disp), "%s (current)", uname);
			else if (signd[0]=='1')   snprintf(disp, sizeof(disp), "%s", uname);
			else                      snprintf(disp, sizeof(disp), "%s - sign in", uname);
			Entry* e = Entry_new("", ENTRY_ROM);
			free(e->name); e->name = strdup(disp);
			// path = [signedin flag][username], e.g. "1alice" / "0bob".
			char pathbuf[160];
			snprintf(pathbuf, sizeof(pathbuf), "%c%s", signd[0], uname);
			free(e->path); e->path = strdup(pathbuf);
			Array_push(lodor_profile_items, e);
		}
		fclose(pf);
	}
}

// lodor: path of the Lodor.pak settings file (KEEP_WIFI_WARM toggle lives here).
static char* Lodor_syncSettingsPath(char* out, int cap) {
	snprintf(out, cap, "%s/Tools/%s/Lodor.pak/settings.conf", SDCARD_PATH, PLATFORM);
	return out;
}

// lodor: read KEEP_WIFI_WARM (default 0) and WIFI_WARM_GRACE (default 120) from settings.conf.
static void Lodor_readWifiWarm(int* warm, int* grace) {
	*warm = 0; *grace = 120;
	char sp[MAX_PATH]; Lodor_syncSettingsPath(sp, sizeof(sp));
	FILE* f = fopen(sp, "r");
	if (!f) return;
	char line[256];
	while (fgets(line, sizeof(line), f)) {
		int v;
		if (sscanf(line, "KEEP_WIFI_WARM=%d", &v)==1) *warm = v ? 1 : 0;
		else if (sscanf(line, "WIFI_WARM_GRACE=%d", &v)==1) *grace = v;
	}
	fclose(f);
}

// lodor: read SHOW_QUALITY_DOTS (default 0 = OFF — the per-system quality dots are opt-in,
// toggled in Lodor Settings). Returns 1 if the dots should be drawn.
static int Lodor_readQualityDots(void) {
	int show = 0; // default OFF (opt-in)
	char sp[MAX_PATH]; Lodor_syncSettingsPath(sp, sizeof(sp));
	FILE* f = fopen(sp, "r");
	if (!f) return show;
	char line[256];
	while (fgets(line, sizeof(line), f)) {
		int v;
		if (sscanf(line, "SHOW_QUALITY_DOTS=%d", &v)==1) show = v ? 1 : 0;
	}
	fclose(f);
	return show;
}

// lodor MULTI-USER: read SHOW_USER_BADGE (default 1 = ON). The corner user badge (the
// active profile's initial) is the visual "who am I synced as" confirmation, shown by
// default and toggleable in Lodor Settings. An absent key => ON.
static int Lodor_readUserBadge(void) {
	int show = 1; // default ON
	char sp[MAX_PATH]; Lodor_syncSettingsPath(sp, sizeof(sp));
	FILE* f = fopen(sp, "r");
	if (!f) return show;
	char line[256];
	while (fgets(line, sizeof(line), f)) {
		int v;
		if (sscanf(line, "SHOW_USER_BADGE=%d", &v)==1) show = v ? 1 : 0;
	}
	fclose(f);
	return show;
}

// lodor #96 (box art): read fetch_covers (default 1 = ON). When ON the engine downloads
// each game's RomM cover during catalog mirror/refresh AND on download; when OFF none are
// fetched. An absent key => ON (the launcher default). The engine reads the SAME key from
// this settings.conf; a numeric 1/0 satisfies both this sscanf and the engine truthy parse.
static int Lodor_readBoxArt(void) {
	int on = 1; // default ON
	char sp[MAX_PATH]; Lodor_syncSettingsPath(sp, sizeof(sp));
	FILE* f = fopen(sp, "r");
	if (!f) return on;
	char line[256];
	while (fgets(line, sizeof(line), f)) {
		int v;
		if (sscanf(line, "fetch_covers=%d", &v)==1) on = v ? 1 : 0;
	}
	fclose(f);
	return on;
}

// lodor: rewrite settings.conf preserving ALL keys we manage; pure file I/O, no WiFi.
// A write never clobbers a sibling toggle (the SHOW_QUALITY_DOTS / KEEP_WIFI_WARM
// coexistence: callers pass the full current state).
// lodor MULTI-USER: path of active-profile.txt — the one-line file holding the SELECTED
// profile label. The per-platform boot script (MinUI.pak/launch.sh) reads it each loop
// iteration to export LODOR_PROFILE + the profile-namespaced SAVES_PATH before launching a
// game, so a profile switched in-menu takes effect on the very next launch. The engine ALSO
// stores active_profile in config.json (--switch-profile); this file is the boot script's
// fast, engine-free read.
static char* Lodor_activeProfilePath(char* out, int cap) {
	snprintf(out, cap, "%s/Tools/%s/Lodor.pak/active-profile.txt", SDCARD_PATH, PLATFORM);
	return out;
}

// lodor MULTI-USER: read the active profile label into out ("" when the file is absent or
// holds "default" — the single-user case). Trims trailing whitespace/newline.
static void Lodor_readActiveProfile(char* out, int cap) {
	out[0] = '\0';
	char ap[MAX_PATH]; Lodor_activeProfilePath(ap, sizeof(ap));
	FILE* f = fopen(ap, "r");
	if (!f) return;
	if (fgets(out, cap, f)) {
		int n = (int)strlen(out);
		while (n > 0 && (out[n-1]=='\n' || out[n-1]=='\r' || out[n-1]==' ' || out[n-1]=='\t')) out[--n] = '\0';
	}
	fclose(f);
	if (strcasecmp(out, "default")==0) out[0] = '\0';
}

// lodor MULTI-USER: the badge initial = first letter of the active profile label, uppercased.
// Returns '\0' when single-user (no badge). Skips leading spaces.
static char Lodor_profileInitial(void) {
	const char* p = lodor_profile_label;
	while (*p==' ' || *p=='\t') p++;
	if (!*p) return '\0';
	char c = *p;
	if (c>='a' && c<='z') c = (char)(c - 'a' + 'A');
	return c;
}

// lodor MULTI-USER: switch the active user. The active-profile.txt content IS the switch
// (the engine's ActiveHost() reads it live every invocation), so writing the file is the
// load-bearing act; we then rebuild this user's library (--mirror-catalog, incremental) so
// the on-card Roms reflect the now-active user. Returns 1 when the file write succeeded
// (the switch took effect); a heavy library rebuild failure does not un-switch the user.
static int Lodor_writeActiveProfile(SDL_Surface* screen, const char* label) {
	char ap[MAX_PATH]; Lodor_activeProfilePath(ap, sizeof(ap));
	// §atomic (#161) PRIORITY: a torn active-profile.txt drops the user to the default profile
	// namespace → saves land in the WRONG namespace. Write it atomically (temp+fsync+rename).
	char buf[MAX_PATH];
	int bn = snprintf(buf, sizeof(buf), "%s\n", label ? label : "");
	int wrote = 0;
	if (bn > 0 && (size_t)bn < sizeof(buf)) wrote = Lodor_atomicWrite(ap, buf, (size_t)bn);
	if (!label || !*label) return wrote; // clearing to single-user: file write is enough
	char cmd[MAX_PATH*2], out[512];
	snprintf(cmd, sizeof(cmd), "'%s%s' --mirror-catalog", SDCARD_PATH, LODOR_ROMM_BIN);
	Lodor_runWithProgress(screen, "Loading library...", cmd, out, sizeof(out));
	return wrote;
}

// fwd decl: Lodor_fillCircle is defined further down with the pending badge primitives.
static void Lodor_fillCircle(SDL_Surface* s, int cx, int cy, int r, Uint32 color);
// lodor MULTI-USER: draw the user badge — a small filled circle bearing the active profile's
// initial, top-RIGHT corner. The "who am I synced as" confirmation. Pure paint; drawn only at
// root and only when SHOW_USER_BADGE is on AND a profile is active.
static void Lodor_drawUserBadge(SDL_Surface* screen) {
	char init = Lodor_profileInitial();
	if (init=='\0') return;
	char lbl[2] = { init, '\0' };
	SDL_Surface* t = TTF_RenderUTF8_Blended(font.medium, lbl, COLOR_WHITE);
	int tw = t?t->w:SCALE1(10), th = t?t->h:SCALE1(14);
	int r = (tw>th?tw:th)/2 + SCALE1(6);
	int cx = screen->w - r - SCALE1(PADDING);
	int cy = r + SCALE1(PADDING);
	Lodor_fillCircle(screen, cx, cy, r, RGB_ACCENT);
	if (t) { SDL_BlitSurface(t, NULL, screen, &(SDL_Rect){cx - tw/2, cy - th/2}); SDL_FreeSurface(t); }
}

// lodor RA: read a single int key (RA_ENABLE / RA_HARDCORE) from settings.conf,
// returning def when the key/file is absent. RA_ENABLE default 1 (RA on once logged
// in), RA_HARDCORE default 0. The same file cheevos.c (minarch) and romm-ra-inject
// (standalone emulators) read at launch, so a toggle here lights up every emulator.
static int Lodor_readRAKey(const char* key, int def) {
	char sp[MAX_PATH]; Lodor_syncSettingsPath(sp, sizeof(sp));
	FILE* f = fopen(sp, "r");
	if (!f) return def;
	char line[256]; int val = def;
	size_t klen = strlen(key);
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, key, klen)==0 && line[klen]=='=') {
			int v; if (sscanf(line+klen+1, "%d", &v)==1) val = v ? 1 : 0;
		}
	}
	fclose(f);
	return val;
}

// lodor: rewrite settings.conf preserving ALL launcher-managed keys (UNION of the box-art and
// RA writers). box_art is passed in (the Box-Art toggle's value); the RA toggles
// (RA_ENABLE/RA_HARDCORE) are NOT passed here, so we read them back BEFORE truncating and re-emit
// them — a WiFi-warm/dots/badge/box-art write never clobbers the RA rows, and vice-versa (see
// Lodor_writeRASettings). All seven managed keys land in one consistent rewrite.
static void Lodor_writeSettings(int warm, int grace, int quality_dots, int user_badge, int box_art) {
	int ra_enable   = Lodor_readRAKey("RA_ENABLE", 1);
	int ra_hardcore = Lodor_readRAKey("RA_HARDCORE", 0);
	char sp[MAX_PATH]; Lodor_syncSettingsPath(sp, sizeof(sp));
	// §atomic (#161): settings.conf via temp+fsync+rename — a torn write drops persisted toggles.
	char body[512];
	int bn = snprintf(body, sizeof(body),
		"KEEP_WIFI_WARM=%d\nWIFI_WARM_GRACE=%d\nSHOW_QUALITY_DOTS=%d\nSHOW_USER_BADGE=%d\nfetch_covers=%d\nRA_ENABLE=%d\nRA_HARDCORE=%d\n",
		warm ? 1 : 0, grace, quality_dots ? 1 : 0, user_badge ? 1 : 0, box_art ? 1 : 0, ra_enable, ra_hardcore);
	if (bn < 0 || (size_t)bn >= sizeof(body)) return;
	Lodor_atomicWrite(sp, body, (size_t)bn);
}

// lodor RA: persist the RA toggles while preserving every sibling key (the inverse of the guard
// in Lodor_writeSettings) — reads back the CURRENT WiFi/dots/badge/box-art values and re-emits all
// seven keys with the new RA values so nothing (incl. fetch_covers) is lost.
static void Lodor_writeRASettings(int ra_enable, int ra_hardcore) {
	int warm, grace; Lodor_readWifiWarm(&warm, &grace);
	char sp[MAX_PATH]; Lodor_syncSettingsPath(sp, sizeof(sp));
	// §atomic (#161): settings.conf via temp+fsync+rename (mirror of Lodor_writeSettings).
	char body[512];
	int bn = snprintf(body, sizeof(body),
		"KEEP_WIFI_WARM=%d\nWIFI_WARM_GRACE=%d\nSHOW_QUALITY_DOTS=%d\nSHOW_USER_BADGE=%d\nfetch_covers=%d\nRA_ENABLE=%d\nRA_HARDCORE=%d\n",
		warm ? 1 : 0, grace, Lodor_readQualityDots() ? 1 : 0, Lodor_readUserBadge() ? 1 : 0,
		Lodor_readBoxArt() ? 1 : 0, ra_enable ? 1 : 0, ra_hardcore ? 1 : 0);
	if (bn < 0 || (size_t)bn >= sizeof(body)) return;
	Lodor_atomicWrite(sp, body, (size_t)bn);
}

// lodor: back-compat shim — toggles WiFi-warm while preserving the quality-dots flag.
static void Lodor_writeWifiWarm(int warm, int grace) {
	Lodor_writeSettings(warm, grace, Lodor_readQualityDots(), Lodor_readUserBadge(), Lodor_readBoxArt());
}

// lodor: blocking A/B confirm rendered like Lodor_drawMessage; returns 1 if A (yes), 0 if B (no).
// Used for the synchronous save-on-download gate and the post-restore confirmation, so the save
// pull always completes BEFORE Entry_open writes /tmp/next (no async input state to wedge).
static int Lodor_inlineConfirm(SDL_Surface* screen, char* msg) {
	PAD_reset();
	GFX_clear(screen);
	GFX_blitHardwareGroup(screen, 0);
	GFX_blitMessage(font.large, msg, screen,
		&(SDL_Rect){ LODOR_OB_SAFE_SIDE, 0, screen->w - LODOR_OB_SAFE_SIDE*2, screen->h }); // §3
	GFX_blitButtonGroup((char*[]){ "B","NO", "A","YES", NULL }, 1, screen, 1);
	GFX_flip(screen);
	for (;;) {
		PAD_poll();
		if (PAD_justPressed(BTN_A)) { PAD_reset(); return 1; }
		if (PAD_justPressed(BTN_B)) { PAD_reset(); return 0; }
		SDL_Delay(16);
	}
}

// lodor: blocking acknowledgement screen (any of A/B dismisses); used so a restore never drops
// silently back to the menu â the user always gets an explicit "restored / couldn't restore".
static void Lodor_inlineAck(SDL_Surface* screen, char* msg) {
	PAD_reset();
	GFX_clear(screen);
	GFX_blitHardwareGroup(screen, 0);
	GFX_blitMessage(font.large, msg, screen,
		&(SDL_Rect){ LODOR_OB_SAFE_SIDE, 0, screen->w - LODOR_OB_SAFE_SIDE*2, screen->h }); // §3
	GFX_blitButtonGroup((char*[]){ "A","OK", NULL }, 0, screen, 1);
	GFX_flip(screen);
	for (;;) {
		PAD_poll();
		if (PAD_justPressed(BTN_A) || PAD_justPressed(BTN_B)) { PAD_reset(); return; }
		SDL_Delay(16);
	}
}

// lodor: after a fresh download, check RomM for an existing save for this ROM and offer to pull
// it so the user continues where they left off (e.g. played on another handheld). Synchronous so
// the restore lands before launch. Reuses --list-saves / Lodor_buildSaves / --restore-save.
// lodor: refresh the "Saves Pending" banner IN PLACE after a successful --push-pending.
// We must NOT call getRoot() again -- getRoot()->hasRecents() Array_pushes onto the global
// recents array without clearing it, so a 2nd call hits the MAX_RECENTS guard and silently
// drops the "Recently Played" row. So we re-count pending-saves.txt and mutate the existing
// banner entry: remove it at 0, or relabel it otherwise. Banner only exists at root.
static void Lodor_refreshBanner(void) {
	if (!top || !exactMatch(top->path, SDCARD_PATH)) return;
	// re-count pending saves exactly like getRoot does (skip blank/whitespace-only lines).
	int np = 0;
	{
		char pp[MAX_PATH];
		sprintf(pp, "%s/Tools/%s/Lodor.pak/pending-saves.txt", SDCARD_PATH, PLATFORM);
		FILE* pf = fopen(pp, "r");
		if (pf) {
			char pl[512];
			while (fgets(pl, sizeof(pl), pf)) {
				char* h = pl; while (*h==' ' || *h=='\t') h++;
				if (*h && *h!='\n' && *h!='\r') np++;
			}
			fclose(pf);
		}
	}
	// find the banner entry: ENTRY_PAK whose name starts with "There are "/"There is ".
	// finding it is itself the root guard (the banner only ever exists at root).
	Array* es = top->entries;
	int bi = -1;
	for (int i=0; i<es->count; i++) {
		Entry* e = es->items[i];
		if (e->type==ENTRY_PAK && e->name &&
		    (strncmp(e->name,"There are ",10)==0 || strncmp(e->name,"There is ",9)==0)) { bi = i; break; }
	}
	if (bi < 0) return; // no banner present -> nothing to do (np>0 w/o banner handled on next reload)
	if (np == 0) {
		// remove the banner entry in place: shift the tail down one, drop count, free it.
		Entry* dead = es->items[bi];
		for (int i=bi; i<es->count-1; i++) es->items[i] = es->items[i+1];
		es->count--;
		Entry_free(dead);
		// fix navigation against the new count, mirroring the existing clamp logic.
		int count = es->count;
		if (top->selected >= count) top->selected = count>0 ? count-1 : 0;
		if (top->selected < 0) top->selected = 0;
		top->start = 0;
		top->end = (count<MAIN_ROW_COUNT) ? count : MAIN_ROW_COUNT;
		if (top->selected >= top->end) {
			top->end = top->selected + 1;
			top->start = top->end - MAIN_ROW_COUNT;
			if (top->start < 0) top->start = 0;
			top->end = (top->start + MAIN_ROW_COUNT < count) ? top->start + MAIN_ROW_COUNT : count;
		}
	} else {
		// some uploaded but a backlog remains -> relabel the banner in place.
		Entry* e = es->items[bi];
		char title[64];
		if (np == 1) strcpy(title, "There is 1 Save Pending");
		else sprintf(title, "There are %d Saves Pending", np);
		free(e->name); e->name = strdup(title);
	}
}
// lodor: refresh the "Continue" tile IN PLACE after a sync rewrote recent.txt. Same constraint as
// the banner — getRoot() can't be re-called (it double-pushes recents) — so re-read recent.txt and
// update / insert / remove the index-0 Continue entry (found by its leading ▶ marker). This is the
// fix for "Continue still showed the old game after a sync".
static void Lodor_refreshContinue(void) {
	if (!top || !exactMatch(top->path, SDCARD_PATH)) return;
	char cpath[MAX_PATH] = "", cgame[256] = "";
	Lodor_continueChoice(cpath, cgame); // newest of server recent.txt vs local last-play.txt
	Array* es = top->entries;
	int ci = -1;
	for (int i=0; i<es->count; i++) {
		Entry* e = es->items[i];
		if (e->name && strncmp(e->name, "\xE2\x96\xB6", 3)==0) { ci = i; break; }
	}
	int valid = (cpath[0] && Lodor_resolveMarkedPath(cpath)); // marker-agnostic (see getRoot)
	if (valid) {
		char ct[320];
		if (cgame[0]) snprintf(ct, sizeof(ct), "\xE2\x96\xB6  Continue \xE2\x80\x94 %s", cgame);
		else          snprintf(ct, sizeof(ct), "\xE2\x96\xB6  Continue");
		if (ci >= 0) {
			Entry* e = es->items[ci];
			free(e->path); e->path = strdup(cpath);
			free(e->name); e->name = strdup(ct);
		} else {
			Entry* e = Entry_new(cpath, ENTRY_ROM);
			free(e->name); e->name = strdup(ct);
			Array_unshift(es, e);
			top->selected++; top->end = (es->count<MAIN_ROW_COUNT)?es->count:MAIN_ROW_COUNT;
		}
	} else if (ci >= 0) {
		Entry* dead = es->items[ci];
		for (int i=ci; i<es->count-1; i++) es->items[i] = es->items[i+1];
		es->count--;
		Entry_free(dead);
		// re-clamp selection/window to the new count (mirrors Lodor_refreshBanner) — without
		// this, a removal while selected==last leaves top->selected past the array end => OOB.
		int count = es->count;
		if (top->selected >= count) top->selected = count>0 ? count-1 : 0;
		if (top->selected < 0) top->selected = 0;
		top->start = 0;
		top->end = (count<MAIN_ROW_COUNT) ? count : MAIN_ROW_COUNT;
		if (top->selected >= top->end) {
			top->end = top->selected + 1;
			top->start = top->end - MAIN_ROW_COUNT;
			if (top->start < 0) top->start = 0;
			top->end = (top->start + MAIN_ROW_COUNT < count) ? top->start + MAIN_ROW_COUNT : count;
		}
	}
}
// lodor: count non-blank lines in pending-saves.txt (the saves waiting to upload). Drives the
// side badge count + whether RIGHT can focus it. Cheap; called per render frame at root.
static int Lodor_pendingCount(void) {
	char pp[MAX_PATH];
	sprintf(pp, "%s/Tools/%s/Lodor.pak/pending-saves.txt", SDCARD_PATH, PLATFORM);
	int np = 0;
	FILE* pf = fopen(pp, "r");
	if (pf) {
		char pl[512];
		while (fgets(pl, sizeof(pl), pf)) {
			char* h = pl; while (*h==' ' || *h=='\t') h++;
			if (*h && *h!='\n' && *h!='\r') np++;
		}
		fclose(pf);
	}
	return np;
}
// lodor: filled circle via per-row scanline FillRect (integer; no math.h). r small (~12px) so it's
// ~2r FillRects per frame, only when a badge is shown.
static void Lodor_fillCircle(SDL_Surface* s, int cx, int cy, int r, Uint32 color) {
	for (int dy=-r; dy<=r; dy++) {
		int w=0; while ((w+1)*(w+1) + dy*dy <= r*r) w++;
		SDL_FillRect(s, &(SDL_Rect){cx-w, cy+dy, 2*w+1, 1}, color);
	}
}
// lodor: draw the pending-saves badge (a "circle bug" with the count) inline ABOVE the LodorOS
// watermark. Accent fill; a cream ring when focused. Returns nothing — pure paint.
static void Lodor_drawBadge(SDL_Surface* screen, int wmx, int wmy, int wmw, int np, int focused) {
	if (np <= 0) return;
	char num[8]; snprintf(num, sizeof(num), "%d", np>99?99:np);
	SDL_Surface* t = TTF_RenderUTF8_Blended(font.large, num, COLOR_WHITE);
	int tw = t?t->w:SCALE1(10), th = t?t->h:SCALE1(14);
	int r = (tw>th?tw:th)/2 + SCALE1(5);
	int cx = wmx + wmw/2;
	int cy = wmy - r - SCALE1(8);              // just above the watermark
	if (cy < r + SCALE1(4)) cy = r + SCALE1(4); // clamp into view
	if (focused) Lodor_fillCircle(screen, cx, cy, r+SCALE1(3), RGB_WHITE); // cream focus ring
	Lodor_fillCircle(screen, cx, cy, r, RGB_ACCENT);
	if (t) { SDL_BlitSurface(t, NULL, screen, &(SDL_Rect){cx - tw/2, cy - th/2}); SDL_FreeSurface(t); }
}
// lodor: HYBRID "synced ✓" signal. The engine (--push-save) writes last-synced.txt as one line
//   "<unix_ts> <count> <basename>"  on a VERIFIED landed push. Lodor_syncedFresh returns 1 (with the
// ts + count) only when that ts is NEWER than the ts already acknowledged in last-synced-ack.txt — so
// the ✓ flashes exactly ONCE after a push and never re-shows once acked. basename may contain spaces
// (it's the line tail), so we parse only the first two whitespace fields. Cheap; read at root only.
static int Lodor_syncedFresh(long* out_ts, int* out_count) {
	char p[MAX_PATH];
	sprintf(p, "%s/Tools/%s/Lodor.pak/last-synced.txt", SDCARD_PATH, PLATFORM);
	FILE* f = fopen(p, "r");
	if (!f) return 0;
	char line[512]; long ts=0; int cnt=0;
	int got = (fgets(line, sizeof(line), f) != NULL);
	fclose(f);
	if (!got) return 0;
	if (sscanf(line, "%ld %d", &ts, &cnt) < 1 || ts <= 0) return 0;
	char ap[MAX_PATH]; long ack=0;
	sprintf(ap, "%s/Tools/%s/Lodor.pak/last-synced-ack.txt", SDCARD_PATH, PLATFORM);
	FILE* af = fopen(ap, "r");
	if (af) { char al[64]; if (fgets(al, sizeof(al), af)) ack = atol(al); fclose(af); }
	if (ts <= ack) return 0;                 // already acknowledged — don't re-flash
	if (out_ts)    *out_ts = ts;
	if (out_count) *out_count = cnt>0 ? cnt : 1;
	return 1;
}
// lodor: persist the acknowledged synced ts so the ✓ flash won't re-show on later frames/boots.
static void Lodor_ackSynced(long ts) {
	char ap[MAX_PATH];
	sprintf(ap, "%s/Tools/%s/Lodor.pak/last-synced-ack.txt", SDCARD_PATH, PLATFORM);
	FILE* af = fopen(ap, "w");
	if (af) { fprintf(af, "%ld\n", ts); fclose(af); }
}
// lodor: draw the transient "synced ✓" confirmation badge — same circle-bug styling as the pending
// badge (accent fill, inline above the watermark) but with a ✓ glyph (and the count when >1) instead
// of the pending number. Shown only when there is NO pending backlog (pending wins — it's actionable).
static void Lodor_drawSyncedBadge(SDL_Surface* screen, int wmx, int wmy, int wmw, int count) {
	char lbl[16];
	if (count>1) snprintf(lbl, sizeof(lbl), "\xE2\x9C\x93%d", count>99?99:count);
	else         snprintf(lbl, sizeof(lbl), "\xE2\x9C\x93");
	SDL_Surface* t = TTF_RenderUTF8_Blended(font.large, lbl, COLOR_WHITE);
	int tw = t?t->w:SCALE1(10), th = t?t->h:SCALE1(14);
	int r = (tw>th?tw:th)/2 + SCALE1(5);
	int cx = wmx + wmw/2;
	int cy = wmy - r - SCALE1(8);
	if (cy < r + SCALE1(4)) cy = r + SCALE1(4);
	Lodor_fillCircle(screen, cx, cy, r, RGB_ACCENT);
	if (t) { SDL_BlitSurface(t, NULL, screen, &(SDL_Rect){cx - tw/2, cy - th/2}); SDL_FreeSurface(t); }
}

// ── FIX 3 (#99): background cover-fetch status pill ─────────────────────────────────
// The engine's `lodor-sync --bg-cover-fetch` worker writes ONE atomic line to
//   Tools/<PLATFORM>/Lodor.pak/bg-task.status :
//   state=running|paused|done|error done=N total=M label="Covers"
// The launcher polls it each frame at root (same cadence as the pending-saves badge) and
// renders a small UPPER-RIGHT pill. NO FAKE PROGRESS: N/M, paused, error, done are exactly
// what the engine wrote — if the file is absent/garbage we draw nothing. A `done` pill is
// shown only briefly (its file mtime within LODOR_BG_DONE_GRACE s) so a completed task
// doesn't leave a permanent badge; running/paused/error always draw while present.
#define LODOR_BG_STATUS_FILE_FMT "%s/Tools/%s/Lodor.pak/bg-task.status"
#define LODOR_BG_DONE_GRACE 15  // seconds a `done` pill lingers before it self-hides
// parsed view of bg-task.status. state: 0=none 1=running 2=paused 3=done 4=error.
typedef struct { int state; int done; int total; char label[24]; } LodorBgStatus;
static int Lodor_readBgStatus(LodorBgStatus* out) {
	out->state = 0; out->done = 0; out->total = 0; out->label[0] = '\0';
	char p[MAX_PATH];
	snprintf(p, sizeof(p), LODOR_BG_STATUS_FILE_FMT, SDCARD_PATH, PLATFORM);
	struct stat st;
	if (stat(p, &st) != 0) return 0;
	FILE* f = fopen(p, "r");
	if (!f) return 0;
	char line[256] = {0};
	int got = (fgets(line, sizeof(line), f) != NULL);
	fclose(f);
	if (!got) return 0;
	// Tolerant key=value scan in any order; only `state=` is mandatory.
	char* sp = strstr(line, "state=");
	if (!sp) return 0;
	char sw[16] = {0};
	sscanf(sp+6, "%15[a-z]", sw);
	int state = 0;
	if      (!strcmp(sw,"running")) state = 1;
	else if (!strcmp(sw,"paused"))  state = 2;
	else if (!strcmp(sw,"done"))    state = 3;
	else if (!strcmp(sw,"error"))   state = 4;
	if (state == 0) return 0;
	char* dp = strstr(line, "done=");  if (dp)  sscanf(dp+5, "%d", &out->done);
	char* tp = strstr(line, "total="); if (tp)  sscanf(tp+6, "%d", &out->total);
	char* lp = strstr(line, "label=\""); if (lp) sscanf(lp+7, "%23[^\"]", out->label);
	if (!out->label[0]) snprintf(out->label, sizeof(out->label), "Covers");
	// self-hide a stale `done` so the pill isn't permanent.
	if (state == 3 && (time(NULL) - st.st_mtime) > LODOR_BG_DONE_GRACE) return 0;
	out->state = state;
	return 1;
}
// Draw the bg status as a small rounded pill in the UPPER-RIGHT corner. Glyphs: running ⟳,
// paused ⏸, done ✓, error !. Built from existing primitives (Lodor_fillCircle end-caps +
// FillRect body); no new asset. Pure paint; called at root only.
static void Lodor_drawBgPill(SDL_Surface* screen, const LodorBgStatus* s, int right_inset) {
	if (!s || s->state == 0) return;
	const char* glyph;
	switch (s->state) {
		case 2:  glyph = "\xE2\x8F\xB8"; break; // ⏸ paused
		case 3:  glyph = "\xE2\x9C\x93"; break; // ✓ done
		case 4:  glyph = "!";            break; //   error
		default: glyph = "\xE2\x9F\xB3"; break; // ⟳ running
	}
	char txt[48];
	if (s->state == 3)                          snprintf(txt, sizeof(txt), "%s %s", glyph, s->label);
	else if (s->state == 4)                     snprintf(txt, sizeof(txt), "%s %s", glyph, s->label);
	else if (s->total > 0)                      snprintf(txt, sizeof(txt), "%s %s %d/%d", glyph, s->label, s->done, s->total);
	else                                        snprintf(txt, sizeof(txt), "%s %s", glyph, s->label);
	SDL_Surface* t = TTF_RenderUTF8_Blended(font.small ? font.small : font.large, txt, COLOR_WHITE);
	if (!t) return;
	int padx = SCALE1(8);
	int h = t->h + SCALE1(6);
	int r = h/2;
	int w = t->w + padx*2;
	int x = screen->w - SCALE1(PADDING) - right_inset - w; // upper-right, left of any user badge
	int y = SCALE1(PADDING);
	Uint32 fill = (s->state == 4) ? RGB_ACCENT : SDL_MapRGB(screen->format, 0x2A, 0x2A, 0x2E);
	// rounded body: two end-cap circles + a central rect (no pill asset needed).
	Lodor_fillCircle(screen, x+r, y+r, r, fill);
	Lodor_fillCircle(screen, x+w-r, y+r, r, fill);
	SDL_FillRect(screen, &(SDL_Rect){x+r, y, w-2*r, h}, fill);
	SDL_BlitSurface(t, NULL, screen, &(SDL_Rect){x+padx, y+(h-t->h)/2});
	SDL_FreeSurface(t);
}

// lodor §toast: queue a transient status message (truthful signals only — see the state
// block at the LodorToast definition). When every slot is taken the OLDEST toast is
// overwritten so fresh news wins. On-screen time is picked per kind: problem kinds
// (offline / fail) linger longer than routine confirmations so they can actually be read.
static void Lodor_toastPush(const char* text, int kind) {
	if (!text || !text[0]) return;
	int slot;
	if (lodor_toast_len == LODOR_TOAST_CAP) {
		slot = lodor_toast_head; // full: reuse the oldest slot...
		lodor_toast_head = (lodor_toast_head + 1) % LODOR_TOAST_CAP; // ...which becomes the tail
	} else {
		slot = (lodor_toast_head + lodor_toast_len) % LODOR_TOAST_CAP;
		lodor_toast_len++;
	}
	LodorToast* t = &lodor_toast_ring[slot];
	snprintf(t->text, sizeof(t->text), "%s", text);
	t->kind = kind;
	t->show_ms = (kind==LODOR_TOAST_OFFLINE || kind==LODOR_TOAST_FAIL) ? 3200 : 2200;
	t->shown_at = 0; // clock starts when it reaches the front (Lodor_toastTick)
}
// lodor §toast: advance the queue. Seats the front toast (stamps its start time) on first
// sight, retires it once its time is up, and reports whether anything is still visible so
// the main loop keeps repainting (the one extra clearing frame is the call site's job).
static int Lodor_toastTick(void) {
	while (lodor_toast_len > 0) {
		LodorToast* front = &lodor_toast_ring[lodor_toast_head];
		unsigned int now = SDL_GetTicks();
		if (front->shown_at == 0) { front->shown_at = now ? now : 1; return 1; } // just seated
		if (now - front->shown_at < front->show_ms) return 1; // unsigned math is wrap-safe
		lodor_toast_head = (lodor_toast_head + 1) % LODOR_TOAST_CAP; // time's up: retire,
		lodor_toast_len--;                                           // loop seats the next one
	}
	return 0;
}
// lodor §toast: paint the front toast bottom-center, above the button-hint row, in the
// file's rounded-pill idiom (two end-cap circles + a center rect). The kind is encoded in
// the pill fill — accent for OK, neutral for info, dim amber for offline ("parked, not
// progressing"), dim red for fail — no glyphs, so no font-coverage surprises. Pure paint.
static void Lodor_drawToast(SDL_Surface* screen) {
	if (lodor_toast_len <= 0) return;
	LodorToast* t = &lodor_toast_ring[lodor_toast_head];
	if (t->shown_at == 0) return; // not seated yet (tick runs before render each frame)
	SDL_Surface* txt = TTF_RenderUTF8_Blended(font.small ? font.small : font.large, t->text, COLOR_WHITE);
	if (!txt) return;
	Uint32 fill;
	switch (t->kind) {
		case LODOR_TOAST_OK:      fill = RGB_ACCENT; break;
		case LODOR_TOAST_OFFLINE: fill = SDL_MapRGB(screen->format, 0x4A, 0x3A, 0x1E); break;
		case LODOR_TOAST_FAIL:    fill = SDL_MapRGB(screen->format, 0x58, 0x20, 0x20); break;
		default:                  fill = SDL_MapRGB(screen->format, 0x2A, 0x2A, 0x2E); break;
	}
	int h = txt->h + SCALE1(8);
	int r = h/2;
	int w = txt->w + SCALE1(2*BUTTON_PADDING);
	if (w < h) w = h; // degenerate short text: keep the caps from crossing
	int x = (screen->w - w)/2; if (x < 0) x = 0;
	int y = screen->h - h - SCALE1(PADDING + PILL_SIZE); // clear of the bottom button hints
	if (y < 0) y = 0;
	Lodor_fillCircle(screen, x+r, y+r, r, fill);
	Lodor_fillCircle(screen, x+w-r, y+r, r, fill);
	SDL_FillRect(screen, &(SDL_Rect){x+r, y, w-2*r, h}, fill);
	SDL_BlitSurface(txt, NULL, screen, &(SDL_Rect){x+(w-txt->w)/2, y+(h-txt->h)/2});
	SDL_FreeSurface(txt);
}
static void Lodor_offerSaveOnDownload(SDL_Surface* screen, const char* rompath) {
	char q1[MAX_PATH*2], cmd[MAX_PATH*3];
	// lodor: opt-in pre-gate -- the device is slow; let the user skip the server lookup.
	if (!Lodor_inlineConfirm(screen, "Check the server for a saved\ngame for this title?\n\nA: Yes   B: Skip")) return;
	Lodor_drawMessage(screen, "Checking for saves...");
	Lodor_shq(rompath, q1, sizeof(q1));
	snprintf(cmd, sizeof(cmd),
		"'%s%s' --list-saves '%s' > /tmp/lodor-saves.txt 2>/dev/null",
		SDCARD_PATH, LODOR_ROMM_BIN, q1);
	system(cmd);
	// Lodor_buildSaves stores save_id in path; reuse lodor_rompath so the list entries point here.
	strncpy(lodor_rompath, rompath, MAX_PATH-1); lodor_rompath[MAX_PATH-1]='\0';
	Lodor_buildSaves();
	if (!lodor_saves_items || lodor_saves_items->count==0) { Lodor_freeSaves(); return; }

	// newest save = first row. label is "<date>  <device>  <size>"; pull device+when back out.
	Entry* newest = lodor_saves_items->items[0];
	char saveid[64];
	strncpy(saveid, newest->path, sizeof(saveid)-1); saveid[sizeof(saveid)-1]='\0';
	char when[64]; when[0]='\0';
	char device[96]; strncpy(device, "another device", sizeof(device)-1); device[sizeof(device)-1]='\0';
	{
		// re-read the first TSV row for clean device/when (label was already collapsed for display).
		FILE* sf = fopen("/tmp/lodor-saves.txt", "r");
		if (sf) {
			char line[512];
			while (fgets(line, sizeof(line), sf)) {
				char* nl = strpbrk(line, "\r\n"); if (nl) *nl='\0';
				if (line[0]=='\0') continue;
				char* id = line;
				char* date = strchr(line, '\t'); if (!date) continue; *date++='\0';
				char* dev  = strchr(date, '\t');  if (dev) *dev++='\0'; else dev="";
				if (dev[0]) { char* t = strchr(dev, '\t'); if (t) *t='\0'; }
				(void)id;
				if (date[0]) { strncpy(when, date, sizeof(when)-1); when[sizeof(when)-1]='\0'; }
				if (dev[0])  { strncpy(device, dev, sizeof(device)-1); device[sizeof(device)-1]='\0'; }
				break; // first (newest) row only
			}
			fclose(sf);
		}
	}
	if (when[0]=='\0') strncpy(when, "a previous session", sizeof(when)-1);
	Lodor_freeSaves();

	char prompt[512];
	snprintf(prompt, sizeof(prompt),
		"Found a save for this game on the\nserver:\n\n%s - %s\n\nDownload it so you can continue?\n\nA: Yes   B: Start fresh",
		device, when);
	if (!Lodor_inlineConfirm(screen, prompt)) return; // B = start fresh, leave local save untouched

	char rcmd[MAX_PATH*3], out[256];
	Lodor_shq(rompath, q1, sizeof(q1));
	snprintf(rcmd, sizeof(rcmd), "'%s%s' --restore-save '%s' %s",
		SDCARD_PATH, LODOR_ROMM_BIN, q1, saveid);
	Lodor_runWithProgress(screen, "Downloading your save...", rcmd, out, sizeof(out));
	int restored = 0;
	{ char* r = strstr(out, "restored="); if (r) restored = atoi(r+9); }
	if (restored) {
		char done[256];
		snprintf(done, sizeof(done), "Save restored - continuing from\n%s's save.", device);
		Lodor_inlineAck(screen, done);
	} else {
		Lodor_inlineAck(screen, "Couldn't restore the save");
	}
}

// lodor: download a 0-byte cloud stub with on-screen feedback, then (if it landed) launch it.
// launch==1 -> Entry_open on success (collection-aware saveLast); launch==0 -> stay on menu.
// Returns 1 if the file is on-device after the call, 0 otherwise.
static int Lodor_downloadThenLaunch(SDL_Surface* screen, Entry* entry, int launch) {
	// already on device? just launch (or report present) without touching WiFi.
	// Lodor_needsFetch is false only when a single-file ROM has real bytes OR a
	// multi-disc .m3u has ALL its discs present-and-nonzero — so a real 183-byte
	// FFVII.m3u whose discs never downloaded falls through to the fetch below
	// instead of being handed straight to the emulator (the black-screen bug).
	if (!Lodor_needsFetch(entry->path)) {
		if (launch) Entry_open(entry);
		return 1;
	}
	char msg[300], q1[MAX_PATH*2], cmd[MAX_PATH*3];
	snprintf(msg, sizeof(msg), "Downloading %s...", entry->name);
	Lodor_shq(entry->path, q1, sizeof(q1));
	// live overlay (replaces the blocking message); wrapper captures output to /tmp/romm-out.
	snprintf(cmd, sizeof(cmd), "'%s%s' --download '%s'",
		SDCARD_PATH, LODOR_ROMM_BIN, q1);
	Lodor_runWithProgress(screen, msg, cmd, NULL, 0);
	if (!Lodor_needsFetch(entry->path)) {
		// fresh download landed: offer to pull the latest server save BEFORE launching, so the
		// restore lands before Entry_open writes /tmp/next. No-op (silent) if there is no save.
		Lodor_offerSaveOnDownload(screen, entry->path);
		if (launch) Entry_open(entry);
		return 1;
	}
	Lodor_drawMessage(screen, "Download failed");
	SDL_Delay(1200);
	return 0;
}

// draw a vertical list of Array<Entry*> with a selection pill, plus a title row.
// used by both the action menu and the server-saves sub-list.
static void Lodor_drawList(SDL_Surface* screen, char* title, Array* items, int sel) {
	GFX_clear(screen);
	int ow = GFX_blitHardwareGroup(screen, 0);

	// title (truncated to screen width)
	char title_buf[320];
	GFX_truncateText(font.large, title, title_buf,
		screen->w - SCALE1(PADDING*2) - ow, SCALE1(BUTTON_PADDING*2));
	SDL_Surface* ttext = TTF_RenderUTF8_Blended(font.large, title_buf, COLOR_WHITE);
	if (ttext) {
		SDL_BlitSurface(ttext, NULL, screen, &(SDL_Rect){
			SCALE1(PADDING+BUTTON_PADDING), SCALE1(PADDING+4)});
		SDL_FreeSurface(ttext);
	}

	// lodor FEATURE 1: right-aligned storage line ("12.4G free / 64G") on the title row of the
	// Sync menu. Set by Lodor_drawList callers via lodor_storage_active; small font, muted color.
	// Cheap: the string is precomputed once on menu open (Lodor_computeStorage).
	if (lodor_storage_active && lodor_storage_str[0] && font.small) {
		SDL_Surface* stext = TTF_RenderUTF8_Blended(font.small, lodor_storage_str, COLOR_GRAY);
		if (stext) {
			int sx = screen->w - SCALE1(PADDING+BUTTON_PADDING) - stext->w;
			if (sx < SCALE1(PADDING)) sx = SCALE1(PADDING); // never run off the left edge
			// vertically center against the large title row
			int sy = SCALE1(PADDING+4) + (TTF_FontHeight(font.large) - stext->h)/2;
			SDL_BlitSurface(stext, NULL, screen, &(SDL_Rect){ sx, sy });
			SDL_FreeSurface(stext);
		}
	}

	int count = items ? items->count : 0;
	// the title occupies row 0; items start at row 1, capped to the visible rows
	for (int i=0; i<count && i<MAIN_ROW_COUNT-1; i++) {
		Entry* it = items->items[i];
		int row = i+1;
		SDL_Color color = COLOR_WHITE;

		char name_buf[256];
		int tw = GFX_truncateText(font.large, it->name, name_buf,
			screen->w - SCALE1(PADDING*2), SCALE1(BUTTON_PADDING*2));
		int max_width = MIN(screen->w - SCALE1(PADDING*2), tw);

		if (i==sel) {
			GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){
				SCALE1(PADDING), SCALE1(PADDING+(row*PILL_SIZE)), max_width, SCALE1(PILL_SIZE)});
			color = COLOR_BLACK;
		}
		SDL_Surface* text = TTF_RenderUTF8_Blended(font.large, name_buf, color);
		if (text) {
			SDL_BlitSurface(text, &(SDL_Rect){0,0,max_width-SCALE1(BUTTON_PADDING*2),text->h},
				screen, &(SDL_Rect){SCALE1(PADDING+BUTTON_PADDING), SCALE1(PADDING+(row*PILL_SIZE)+4)});
			SDL_FreeSurface(text);
		}
	}
	GFX_blitButtonGroup((char*[]){ "B","BACK", "A","SELECT", NULL }, 1, screen, 1);
	GFX_flip(screen);
}

// ════════════════════════════════════════════════════════════════════════════════════
// lodor §tailscale: QR onboarding — capability gate, QR renderer, the 3-mode chooser +
// LAN form, the shared server-submit, and the blocking Tailscale sign-in sub-flow.
// All of this is purely additive: the existing WELCOME/WIFI/SERVER/PAIR/DEVICE steps are
// untouched except that WELCOME/WIFI now route into the MODE chooser instead of straight
// into the SERVER form, and the three modes converge back on the unchanged PAIR step.
// ════════════════════════════════════════════════════════════════════════════════════

// Is the Tailscale mode usable on THIS device? HARD gate: never on miyoomini (128 MB),
// and only when the userspace daemon was actually bundled for this build/arch (the
// release packs it per-capable-platform). When this returns 0 the chooser hides the
// Tailscale row entirely, so an incapable device never sees a dead option.
static int Lodor_tailscaleAvailable(void) {
	if (strcmp(PLATFORM, "miyoomini") == 0) return 0;       // 128 MB — hard no
	if (strcmp(PLATFORM, "my282") == 0) return 0;           // A30 512 MB — hard no (A33 firmware + RAM too marginal; 2026-07-01)
	char p[MAX_PATH];
	snprintf(p, sizeof(p), "%s%s", SDCARD_PATH, LODOR_TS_DAEMON);
	if (access(p, X_OK) == 0) return 1;                    // legacy per-pak path
	// deduped: shared per-arch daemon at .system/.tailscale/<arch>/tailscaled
	struct utsname uts; const char *arch = "armhf";
	if (uname(&uts) == 0 && (strstr(uts.machine, "aarch64") || strstr(uts.machine, "arm64"))) arch = "arm64";
	snprintf(p, sizeof(p), "%s/.system/.tailscale/%s/tailscaled", SDCARD_PATH, arch);
	return access(p, X_OK) == 0;                            // shared dedup binary?
}

// Render a QR code for `text` as filled black modules on a white quiet-zone panel,
// centered horizontally, with its top at top_y and sized to fit min(max_h, panel
// width). Returns the panel's pixel size (so the caller can place text below it), or 0
// if encoding failed. Uses Nayuki qrcodegen (ECC LOW so the smallest version is picked
// for the short login URL → the biggest modules on a tiny screen). Logs the module
// count to stderr once (the build-time sanity check asserts the same numbers).
static int Lodor_drawQR(SDL_Surface* screen, const char* text, int top_y, int max_h) {
	if (!text || !text[0]) return 0;
	uint8_t qr[qrcodegen_BUFFER_LEN_MAX];
	uint8_t tmp[qrcodegen_BUFFER_LEN_MAX];
	bool ok = qrcodegen_encodeText(text, tmp, qr, qrcodegen_Ecc_LOW,
		qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX, qrcodegen_Mask_AUTO, true);
	if (!ok) return 0;
	int size = qrcodegen_getSize(qr);                       // modules per side (21..177)
	if (size <= 0) return 0;
	const int quiet = 3;                                    // quiet-zone modules each side
	int total = size + quiet * 2;
	int availw = screen->w - SCALE1(PADDING * 2);
	int dim = (max_h < availw) ? max_h : availw;
	if (dim < total) dim = total;                           // floor: at least 1 px/module
	int mod = dim / total; if (mod < 1) mod = 1;
	int panel = total * mod;
	int px = (screen->w - panel) / 2; if (px < 0) px = 0;
	int py = top_y;
	SDL_FillRect(screen, &(SDL_Rect){ px, py, panel, panel }, RGB_WHITE);
	int ox = px + quiet * mod, oy = py + quiet * mod;
	for (int y = 0; y < size; y++)
		for (int x = 0; x < size; x++)
			if (qrcodegen_getModule(qr, x, y))
				SDL_FillRect(screen, &(SDL_Rect){ ox + x * mod, oy + y * mod, mod, mod }, RGB_BLACK);
	static int logged = 0;
	if (!logged) { fprintf(stderr, "lodor-qr: %d modules, %dpx/module, panel=%dpx\n", size, mod, panel); logged = 1; }
	return panel;
}

// blit `s` horizontally centered at y in `col`; returns the y just below it.
static int Lodor_blitCentered(SDL_Surface* screen, TTF_Font* f, const char* s, int y, SDL_Color col) {
	if (!f || !s || !s[0]) return y;
	SDL_Surface* t = TTF_RenderUTF8_Blended(f, (char*)s, col);
	if (!t) return y;
	int x = (screen->w - t->w) / 2; if (x < 0) x = 0;
	SDL_BlitSurface(t, NULL, screen, &(SDL_Rect){ x, y });
	int h = t->h; SDL_FreeSurface(t);
	return y + h;
}

// Build the visible MODE rows honoring the capability gate. LAN is always row 0 (the
// highlighted default); Tailscale only appears when available; Advanced is always last.
// Fills labels[]/modes[] and returns the row count (2 or 3).
static int Lodor_obModeRows(const char* labels[3], int modes[3]) {
	int n = 0;
	labels[n] = "Home network (LAN)";            modes[n] = LODOR_OB_MODE_LAN; n++;
	if (Lodor_tailscaleAvailable()) { labels[n] = "Tailscale (private, anywhere)"; modes[n] = LODOR_OB_MODE_TS; n++; }
	labels[n] = "Advanced (public URL)";         modes[n] = LODOR_OB_MODE_ADV; n++;
	return n;
}

// Render the "How will you reach RomM?" chooser: title row + pill-highlighted mode rows
// + a small grey description for the selected mode. Mirrors Lodor_drawList's pill style.
static void Lodor_obDrawModeChooser(SDL_Surface* screen) {
	const char* labels[3]; int modes[3];
	int n = Lodor_obModeRows(labels, modes);
	if (lodor_ob_mode_sel >= n) lodor_ob_mode_sel = n - 1;
	if (lodor_ob_mode_sel < 0) lodor_ob_mode_sel = 0;

	GFX_clear(screen);
	GFX_blitHardwareGroup(screen, 0);
	SDL_Surface* tt = TTF_RenderUTF8_Blended(font.large, "How will you reach RomM?", COLOR_WHITE);
	if (tt) { SDL_BlitSurface(tt, NULL, screen, &(SDL_Rect){ SCALE1(PADDING + BUTTON_PADDING), SCALE1(PADDING + 4) }); SDL_FreeSurface(tt); }

	for (int i = 0; i < n; i++) {
		int row = i + 1; SDL_Color color = COLOR_WHITE;
		char name_buf[256];
		int tw = GFX_truncateText(font.large, (char*)labels[i], name_buf,
			screen->w - SCALE1(PADDING * 2), SCALE1(BUTTON_PADDING * 2));
		int max_width = MIN(screen->w - SCALE1(PADDING * 2), tw);
		if (i == lodor_ob_mode_sel) {
			GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){
				SCALE1(PADDING), SCALE1(PADDING + (row * PILL_SIZE)), max_width, SCALE1(PILL_SIZE) });
			color = COLOR_BLACK;
		}
		SDL_Surface* text = TTF_RenderUTF8_Blended(font.large, name_buf, color);
		if (text) {
			SDL_BlitSurface(text, &(SDL_Rect){ 0, 0, max_width - SCALE1(BUTTON_PADDING * 2), text->h },
				screen, &(SDL_Rect){ SCALE1(PADDING + BUTTON_PADDING), SCALE1(PADDING + (row * PILL_SIZE) + 4) });
			SDL_FreeSurface(text);
		}
	}

	const char* desc = "";
	if      (modes[lodor_ob_mode_sel] == LODOR_OB_MODE_LAN) desc = "RomM on this same Wi-Fi - the easy default.\nTip: use a hostname or DHCP reservation, not a bare IP.";
	else if (modes[lodor_ob_mode_sel] == LODOR_OB_MODE_TS)  desc = "Reach RomM from anywhere over your own private\nTailscale network. You sign in with a QR code.";
	else                                                    desc = "Type a full public URL (protocol, host, port, SSL).\nFor a Cloudflare Tunnel or reverse proxy.";
	if (font.small) {
		int dy = SCALE1(PADDING + ((n + 2) * PILL_SIZE));
		char dbuf[256]; snprintf(dbuf, sizeof(dbuf), "%s", desc);
		char* p = dbuf;
		while (p && *p) {
			char* nl = strchr(p, '\n'); if (nl) *nl = '\0';
			char tl[256]; GFX_truncateText(font.small, p, tl, screen->w - SCALE1(PADDING * 2), 0);
			SDL_Surface* dt = TTF_RenderUTF8_Blended(font.small, tl, COLOR_GRAY);
			if (dt) { SDL_BlitSurface(dt, NULL, screen, &(SDL_Rect){ SCALE1(PADDING + BUTTON_PADDING), dy }); dy += dt->h; SDL_FreeSurface(dt); }
			if (!nl) break; p = nl + 1;
		}
	}
	GFX_blitButtonGroup((char*[]){ "B", "BACK", "A", "SELECT", NULL }, 1, screen, 1);
	GFX_flip(screen);
}

// Render the LAN host form: a 2-row field list (Hostname / Port), focused row pilled,
// plus a small grey recommendation. LAN is intentionally http-only and proxy-free (a
// plain tier-0 host); HTTPS / public URLs are the Advanced form's job.
static void Lodor_obDrawLanForm(SDL_Surface* screen) {
	GFX_clear(screen);
	GFX_blitHardwareGroup(screen, 0);
	SDL_Surface* tt = TTF_RenderUTF8_Blended(font.large, "Home network (LAN)", COLOR_WHITE);
	if (tt) { SDL_BlitSurface(tt, NULL, screen, &(SDL_Rect){ SCALE1(PADDING + BUTTON_PADDING), SCALE1(PADDING + 4) }); SDL_FreeSurface(tt); }
	const char* names[2] = { "Hostname", "Port" };
	int fids[2] = { LODOR_OB_F_HOST, LODOR_OB_F_PORT };
	for (int i = 0; i < 2; i++) {
		int row = i + 1; SDL_Color color = COLOR_WHITE;
		char line[200];
		snprintf(line, sizeof(line), "%s: %s", names[i],
			i == 0 ? (lodor_ob_host[0] ? lodor_ob_host : "(set me)")
			       : (lodor_ob_port[0] ? lodor_ob_port : "(none)"));
		char name_buf[256];
		int tw = GFX_truncateText(font.large, line, name_buf, screen->w - SCALE1(PADDING * 2), SCALE1(BUTTON_PADDING * 2));
		int max_width = MIN(screen->w - SCALE1(PADDING * 2), tw);
		if (fids[i] == lodor_ob_field) {
			GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){
				SCALE1(PADDING), SCALE1(PADDING + (row * PILL_SIZE)), max_width, SCALE1(PILL_SIZE) });
			color = COLOR_BLACK;
		}
		SDL_Surface* text = TTF_RenderUTF8_Blended(font.large, name_buf, color);
		if (text) {
			SDL_BlitSurface(text, &(SDL_Rect){ 0, 0, max_width - SCALE1(BUTTON_PADDING * 2), text->h },
				screen, &(SDL_Rect){ SCALE1(PADDING + BUTTON_PADDING), SCALE1(PADDING + (row * PILL_SIZE) + 4) });
			SDL_FreeSurface(text);
		}
	}
	if (font.small) {
		int dy = SCALE1(PADDING + (4 * PILL_SIZE));
		const char* lines[3] = {
			"Your RomM address on this Wi-Fi (connects over http).",
			"Use a hostname or DHCP reservation, not a raw IP.",
			"For HTTPS or a public URL, go Back and pick Advanced."
		};
		for (int i = 0; i < 3; i++) {
			char tl[256]; GFX_truncateText(font.small, (char*)lines[i], tl, screen->w - SCALE1(PADDING * 2), 0);
			SDL_Surface* dt = TTF_RenderUTF8_Blended(font.small, tl, COLOR_GRAY);
			if (dt) { SDL_BlitSurface(dt, NULL, screen, &(SDL_Rect){ SCALE1(PADDING + BUTTON_PADDING), dy }); dy += dt->h; SDL_FreeSurface(dt); }
		}
	}
	GFX_blitButtonGroup((char*[]){ "B", "BACK", "A", "EDIT", "START", "CONNECT", NULL }, 1, screen, 1);
	GFX_flip(screen);
}

// Shared server submit (used by SERVER/LAN/TS_HOST): persist `url` (scheme+host) + the
// optional `port`/`insecure` via the engine's --set-server, then --validate. Returns 1
// only when saved AND reachable (caller advances to PAIR); 0 otherwise (an inline ack
// already explained why; the caller keeps the form so edits are preserved). The engine
// owns config.json — this just shells the same primitives the original SERVER step did.
static int Lodor_obSubmitServer(SDL_Surface* screen, const char* url, const char* port, int insecure) {
	char qurl[LODOR_OB_HOST_MAX + 32]; Lodor_shq(url, qurl, sizeof(qurl));
	char cmd[MAX_PATH * 3], out[1024];
	if (port && port[0]) {
		char qport[16]; Lodor_shq(port, qport, sizeof(qport));
		snprintf(cmd, sizeof(cmd), "'%s%s' --set-server '%s' --port '%s'%s",
			SDCARD_PATH, LODOR_ROMM_BIN, qurl, qport, insecure ? " --insecure" : "");
	} else {
		snprintf(cmd, sizeof(cmd), "'%s%s' --set-server '%s'%s",
			SDCARD_PATH, LODOR_ROMM_BIN, qurl, insecure ? " --insecure" : "");
	}
	int server_set = 0;
	Lodor_runWithProgress(screen, "Saving server...", cmd, out, sizeof(out));
	{ char* ln = out; while (ln && *ln) { int v; if (sscanf(ln, "RESULT server_set=%d", &v) == 1) server_set = v; char* nx = strchr(ln, '\n'); ln = nx ? nx + 1 : NULL; } }
	if (!server_set) {
		if (strstr(out, "invalid url"))
			Lodor_inlineAck(screen, "That address doesn't look right.\nCheck the hostname and try again.");
		else
			Lodor_inlineAck(screen, "Couldn't save the server.\nCheck the address and retry.");
		return 0;
	}
	int reachable = 0, auth = 0; (void)auth;
	snprintf(cmd, sizeof(cmd), "'%s%s' --validate", SDCARD_PATH, LODOR_ROMM_BIN);
	Lodor_runWithProgress(screen, "Reaching RomM...", cmd, out, sizeof(out));
	{ char* ln = out; while (ln && *ln) { int r, a; if (sscanf(ln, "RESULT reachable=%d auth=%d", &r, &a) == 2) { reachable = r; auth = a; } char* nx = strchr(ln, '\n'); ln = nx ? nx + 1 : NULL; } }
	if (!reachable) {
		Lodor_inlineAck(screen, "Couldn't reach RomM at that address.\nFor Tailscale use the .ts.net name (not\nthe 100.x IP); for home use the LAN IP.");
		return 0;
	}
	return 1;
}

// Blocking Tailscale QR sign-in sub-flow. Brings up userspace tailscaled + interactive
// `tailscale up` (NO auth key) via the romm-tailscale shell entrypoint, scrapes the
// https://login.tailscale.com/... URL it prints, renders that as a QR + the URL text
// with a "scan to sign in" prompt, then polls `tailscale status` (~2s cadence; B cancels)
// until the node reports Connected. Every ~5 min of no sign-in it ASKS whether to keep
// waiting instead of expiring: the pending login URL stays valid on the still-running
// daemon, so a phone flow the user is mid-completing (SSO, 2FA, a feeding break) is never
// silently discarded — the 2026-07-05 Flip field failure was exactly a hard cap tearing
// down a pending auth. Returns 1 on connect (caller then asks for the *.ts.net host),
// 0 on cancel/failure (caller stays on the chooser). Owns the screen for its duration.
// HONEST LIMIT: the actual tailscaled CLI handshake can only be proven on-device — this
// builds the UI + scrape + poll; the runtime interaction is the on-hardware unknown.
static int Lodor_obTailscaleFlow(SDL_Surface* screen) {
	char cmd[MAX_PATH * 2], out[2048];
	snprintf(cmd, sizeof(cmd), "'%s%s' up", SDCARD_PATH, LODOR_TS_BIN);
	Lodor_runWithProgress(screen, "Starting Tailscale...", cmd, out, sizeof(out));

	// scrape RESULT ts_url=<login url> (robust to surrounding text: match the prefix, take
	// up to end-of-line, then require it to be a real login.tailscale.com URL).
	char url[512]; url[0] = '\0';
	{
		char* m = strstr(out, "RESULT ts_url=");
		if (m) {
			m += strlen("RESULT ts_url=");
			int i = 0;
			while (m[i] && m[i] != '\r' && m[i] != '\n' && i < (int)sizeof(url) - 1) { url[i] = m[i]; i++; }
			url[i] = '\0';
		}
	}
	if (strncmp(url, "https://login.tailscale.com/", 28) != 0) {
		// No login URL is NOT always failure: tailscale_up_interactive returns an EMPTY
		// url when the node is ALREADY signed in (persisted state) -- the QR step is then
		// unnecessary. Check status first so re-onboarding an already-authed device
		// proceeds, instead of the deterministic post-sign-in false "Couldn't start".
		char scmd[MAX_PATH * 2], sout[512];
		snprintf(scmd, sizeof(scmd), "'%s%s' status 2>/dev/null", SDCARD_PATH, LODOR_TS_BIN);
		int already = 0;
		FILE* spf = popen(scmd, "r");
		if (spf) { size_t sn = fread(sout, 1, sizeof(sout) - 1, spf); sout[sn] = '\0'; pclose(spf); if (strstr(sout, "ts_state=connected")) already = 1; }
		if (already) {
			Lodor_inlineAck(screen, "Tailscale already signed in.");
			return 1;
		}
		// Diagnosable failure: the raw `up` output head lands in the launcher log
		// (.userdata/<plat>/logs/minui.txt) so a field "Couldn't start" is never a dead end.
		fprintf(stderr, "lodor-ts: no login URL in up output (head: %.200s)\n", out);
		// The daemon may have started anyway (URL lost between shim and scrape, not
		// bring-up failure) — tear it down so a half-started tailscaled never lingers
		// behind an error screen.
		{
			char dcmd[MAX_PATH * 2], dout[256];
			snprintf(dcmd, sizeof(dcmd), "'%s%s' down", SDCARD_PATH, LODOR_TS_BIN);
			Lodor_runWithProgress(screen, "Tidying up...", dcmd, dout, sizeof(dout));
		}
		Lodor_inlineAck(screen,
			"Couldn't start Tailscale sign-in.\nCheck Wi-Fi, or use Home network / Advanced.\nStill stuck? Tools > Tailscale > Reset & forget.");
		return 0;
	}
	fprintf(stderr, "lodor-ts: login URL captured; waiting for the phone sign-in\n");

	Uint32 start = SDL_GetTicks();
	Uint32 last_poll = 0;
	int connected = 0;
	int frame = 0;
	char urlline[256];
	GFX_truncateText(font.small ? font.small : font.large, url, urlline, screen->w - SCALE1(PADDING * 2), 0);

	while (1) {
		Uint32 now = SDL_GetTicks();
		if (now - start > 300000) {                      // ~5 min: ask, never expire silently
			// Do NOT tear the daemon down here — the login URL is still pending on it, so
			// a sign-in the user completes while this prompt is up STILL lands, and "keep
			// waiting" resumes polling the same URL (a retry would re-scrape the identical
			// AuthURL from the daemon's status JSON anyway).
			if (Lodor_inlineConfirm(screen,
				"Still waiting for the phone sign-in.\n\nKeep waiting?\n(The code on screen stays valid.)")) {
				start = SDL_GetTicks();
				last_poll = 0;                           // poll immediately on resume
				continue;
			}
			break;                                       // user gave up: tidy up below
		}

		PAD_poll();
		if (PAD_justPressed(BTN_B)) {                    // cancel: tear the daemon down
			char dcmd[MAX_PATH * 2], dout[256];
			snprintf(dcmd, sizeof(dcmd), "'%s%s' down", SDCARD_PATH, LODOR_TS_BIN);
			Lodor_runWithProgress(screen, "Cancelling...", dcmd, dout, sizeof(dout));
			return 0;
		}

		if (last_poll == 0 || now - last_poll >= 2000) { // poll status ~every 2s
			last_poll = now;
			char scmd[MAX_PATH * 2], sout[512];
			snprintf(scmd, sizeof(scmd), "'%s%s' status 2>/dev/null", SDCARD_PATH, LODOR_TS_BIN);
			FILE* pf = popen(scmd, "r");
			if (pf) {
				size_t n = fread(sout, 1, sizeof(sout) - 1, pf); sout[n] = '\0'; pclose(pf);
				if (strstr(sout, "ts_state=connected")) connected = 1;
			}
			if (connected) break;
		}

		GFX_clear(screen);
		GFX_blitHardwareGroup(screen, 0);
		int y = LODOR_OB_SAFE_TOP;
		y = Lodor_blitCentered(screen, font.large, "Sign in to Tailscale", y, COLOR_WHITE);
		y += SCALE1(4);
		int qmax = screen->h - y - SCALE1(PILL_SIZE * 5);
		int qpanel = Lodor_drawQR(screen, url, y, qmax);
		y += (qpanel > 0 ? qpanel : 0) + SCALE1(6);
		if (qpanel <= 0) y = Lodor_blitCentered(screen, font.large, "(couldn't render the QR - use the link)", y, COLOR_WHITE);
		y = Lodor_blitCentered(screen, font.small ? font.small : font.large, "Scan with your phone to sign in", y, COLOR_WHITE);
		y = Lodor_blitCentered(screen, font.small ? font.small : font.large, urlline, y, COLOR_GRAY);
		y = Lodor_blitCentered(screen, font.small ? font.small : font.large, "Can't scan? Type the link above into your phone's browser", y, COLOR_GRAY);
		Lodor_blitCentered(screen, font.small ? font.small : font.large, "Waiting for sign-in...", y + SCALE1(4), COLOR_GRAY);
		GFX_blitButtonGroup((char*[]){ "B", "CANCEL", NULL }, 1, screen, 1);
		GFX_flip(screen);
		SDL_Delay(60);
		frame++;
	}

	if (!connected) {
		// Only reached when the user explicitly declined to keep waiting — say that,
		// not "timed out" (nothing expired; they chose to stop).
		char dcmd[MAX_PATH * 2], dout[256];
		snprintf(dcmd, sizeof(dcmd), "'%s%s' down", SDCARD_PATH, LODOR_TS_BIN);
		Lodor_runWithProgress(screen, "Tidying up...", dcmd, dout, sizeof(dout));
		Lodor_inlineAck(screen, "Tailscale sign-in cancelled.\nTry again anytime, or use Home network / Advanced.\nStill stuck? Tools > Tailscale > Reset & forget.");
		return 0;
	}
	return 1;
}

// lodor: shared on-screen-keyboard INPUT handler, extracted verbatim from the onboarding
// wizard's keyboard sub-mode so the RetroAchievements overlay can reuse the exact same key
// grid / navigation / DONE / cancel semantics (it edits whatever lodor_ob_kb_buf points at).
// Behavior is byte-identical to the inline onboarding version (only `dirty` -> `*dp`).
static void Lodor_kbInput(int* dp) {
	int isURL = lodor_ob_kb_url;
	if (PAD_justRepeated(BTN_UP)) {
		if (isURL && lodor_kb_row==0) { lodor_kb_row = -1; } // onto the shortcut row
		else if (lodor_kb_row==-1) { lodor_kb_row = LODOR_KB_ROWS-1; Lodor_kbSnapSpecial(); }
		else { lodor_kb_row = (lodor_kb_row-1+LODOR_KB_ROWS)%LODOR_KB_ROWS; if (lodor_kb_row==LODOR_KB_ROWS-1) Lodor_kbSnapSpecial(); }
		*dp = 1;
	}
	else if (PAD_justRepeated(BTN_DOWN)) {
		if (lodor_kb_row==-1) { lodor_kb_row = 0; }
		else { lodor_kb_row = (lodor_kb_row+1)%LODOR_KB_ROWS; if (lodor_kb_row==LODOR_KB_ROWS-1) Lodor_kbSnapSpecial(); else if (isURL && lodor_kb_row==0) {} }
		*dp = 1;
	}
	else if (PAD_justRepeated(BTN_LEFT)) {
		if (lodor_kb_row==-1) { lodor_ob_sc_sel = (lodor_ob_sc_sel-1+LODOR_OB_URL_SC_COUNT)%LODOR_OB_URL_SC_COUNT; }
		else if (lodor_kb_row==LODOR_KB_ROWS-1) {
			int order[3] = { LODOR_KB_GO_COL, LODOR_KB_DEL_COL, LODOR_KB_SPACE_COL };
			for (int i=0;i<3;i++) if (lodor_kb_col==order[i]) { lodor_kb_col = order[(i+1)%3]; break; }
		} else lodor_kb_col = (lodor_kb_col-1+LODOR_KB_COLS)%LODOR_KB_COLS;
		*dp = 1;
	}
	else if (PAD_justRepeated(BTN_RIGHT)) {
		if (lodor_kb_row==-1) { lodor_ob_sc_sel = (lodor_ob_sc_sel+1)%LODOR_OB_URL_SC_COUNT; }
		else if (lodor_kb_row==LODOR_KB_ROWS-1) {
			int order[3] = { LODOR_KB_SPACE_COL, LODOR_KB_DEL_COL, LODOR_KB_GO_COL };
			for (int i=0;i<3;i++) if (lodor_kb_col==order[i]) { lodor_kb_col = order[(i+1)%3]; break; }
		} else lodor_kb_col = (lodor_kb_col+1)%LODOR_KB_COLS;
		*dp = 1;
	}
	else if (PAD_justPressed(BTN_L1)) { lodor_kb_layer = (lodor_kb_layer-1+LODOR_KB_LAYERS)%LODOR_KB_LAYERS; *dp = 1; } // #97: cycle abc <- ABC <- 123
	else if (PAD_justPressed(BTN_R1)) { lodor_kb_layer = (lodor_kb_layer+1)%LODOR_KB_LAYERS; *dp = 1; } // #97: cycle abc -> ABC -> 123
	else if (PAD_justPressed(BTN_A)) {
		int len = lodor_ob_kb_buf ? (int)strlen(lodor_ob_kb_buf) : 0;
		if (lodor_kb_row==-1) {
			// append the selected URL shortcut to the hostname
			const char* sc = lodor_ob_url_shortcuts[lodor_ob_sc_sel];
			int sl = strlen(sc);
			if (len + sl < lodor_ob_kb_cap-1) { strcpy(lodor_ob_kb_buf+len, sc); }
		}
		else if (lodor_kb_row < 4) {
			char ch = LODOR_KB_CH(lodor_kb_row, lodor_kb_col);
			int allow = 1;
			if (lodor_ob_kb_numeric && !(ch>='0' && ch<='9')) allow = 0;
			if (allow && len < lodor_ob_kb_cap-1) {
				// lowercase letters for hostnames (URL mode) — DNS is case-insensitive
				// but lowercase is conventional and matches what users type elsewhere.
				if (isURL && ch>='A' && ch<='Z') ch = ch - 'A' + 'a';
				lodor_ob_kb_buf[len] = ch; lodor_ob_kb_buf[len+1]='\0';
			}
		}
		else if (lodor_kb_col==LODOR_KB_SPACE_COL) {
			// space only meaningful for device-name (not host/port/code)
			if (!isURL && !lodor_ob_kb_numeric && lodor_ob_kb_buf!=lodor_ob_code && len < lodor_ob_kb_cap-1) { lodor_ob_kb_buf[len]=' '; lodor_ob_kb_buf[len+1]='\0'; }
		}
		else if (lodor_kb_col==LODOR_KB_DEL_COL) {
			if (len>0) lodor_ob_kb_buf[len-1]='\0';
		}
		else if (lodor_kb_col==LODOR_KB_GO_COL) {
			lodor_ob_kb_active = 0; lodor_ob_kb_cancelled = 0; // [DONE] confirms, keeps buffer
		}
		*dp = 1;
	}
	else if (PAD_justPressed(BTN_START)) {
		lodor_ob_kb_active = 0; lodor_ob_kb_cancelled = 0; *dp = 1; // START confirms
	}
	else if (PAD_justPressed(BTN_B)) {
		lodor_ob_kb_active = 0; lodor_ob_kb_cancelled = 1; *dp = 1; // B cancels (back out)
	}
}

// FEATURE 2 (optional UX): if the ACTIVE profile's token has admin scope, list the
// EXISTING server users (GET /api/users via the engine --list-users) and let the user
// pick one for Add-Profile sign-in. Returns 1 and fills `out` with the chosen username
// when a real user is selected; returns 0 to fall back to a free-text username prompt
// (not admin / endpoint failed / empty list / user chose "Other" / cancelled). NEVER
// creates a user — read-only. A picked username is a public handle; the password is
// always prompted separately afterward.
static int Lodor_pickServerUser(SDL_Surface* screen, char* out, int cap) {
	if (!out || cap <= 0) return 0;
	out[0] = '\0';

	char cmd[MAX_PATH*2];
	snprintf(cmd, sizeof(cmd), "'%s%s' --list-users > /tmp/lodor-users.txt 2>/dev/null", SDCARD_PATH, LODOR_ROMM_BIN);
	system(cmd);

	Array* items = Array_new(); // Entry*: name=display, path=raw username ("" = Other)
	FILE* uf = fopen("/tmp/lodor-users.txt", "r");
	if (uf) {
		char line[256];
		while (fgets(line, sizeof(line), uf)) {
			char* nl = strpbrk(line, "\r\n"); if (nl) *nl='\0';
			if (line[0]=='\0') continue;
			if (strncmp(line, "RESULT ", 7)==0) continue; // skip the trailing RESULT users=N line
			Entry* e = Entry_new("", ENTRY_ROM);
			free(e->name); e->name = strdup(line);
			free(e->path); e->path = strdup(line);
			Array_push(items, e);
		}
		fclose(uf);
	}

	if (items->count == 0) { EntryArray_free(items); return 0; } // not admin / no users -> free-text

	// Append an explicit free-text escape hatch.
	{ Entry* e = Entry_new("", ENTRY_ROM); free(e->name); e->name = strdup("Other (type a username)"); free(e->path); e->path = strdup(""); Array_push(items, e); }

	int sel = 0, count = items->count;
	PAD_reset();
	for (;;) {
		PAD_poll();
		if (PAD_justRepeated(BTN_UP))   { sel = (sel-1+count)%count; }
		else if (PAD_justRepeated(BTN_DOWN)) { sel = (sel+1)%count; }
		else if (PAD_justPressed(BTN_B)) { EntryArray_free(items); PAD_reset(); return 0; } // back -> free-text
		else if (PAD_justPressed(BTN_A)) {
			Entry* it = items->items[sel];
			int picked = (it->path && it->path[0]) ? 1 : 0; // "" = Other -> free-text
			if (picked) { strncpy(out, it->path, cap-1); out[cap-1]='\0'; }
			EntryArray_free(items); PAD_reset();
			return picked;
		}
		Lodor_drawList(screen, "Sign in as", items, sel);
		SDL_Delay(16);
	}
}

///////////////////////////////////////
// lodor §CJK: optional CJK-capable UI font, opt-in by dropping a TTF at
// SDCARD/.system/res/cjk.ttf. SDL_ttf 1.2 (USE_SDL) has no per-glyph fallback, so JP/CN/KR
// ROM names render as tofu under the stock Latin-only font; a user-supplied font carrying
// both Latin and CJK glyph sets (Noto Sans CJK, WenQuanYi, ...) fixes menus and ROM names
// at once. Runs once at startup, after GFX_init seats the stock fonts: every `font` slot
// is re-opened from the TTF at its usual size, and the swap is ALL-OR-NOTHING — if any
// size fails to open, everything opened so far is closed and the stock fonts stay. Pure
// software TTF swap, no GL, no new dependency. (NextUI also offers a user-selectable UI
// font; this implementation is Lodor's own.)
#define LODOR_CJK_FONT_PATH RES_PATH "/cjk.ttf"
static void Lodor_applyCJKFont(void) {
	if (!exists(LODOR_CJK_FONT_PATH)) return; // opt-in: no file, nothing to do
	struct { TTF_Font** slot; int pt; } slots[] = {
		{ &font.large,  SCALE1(FONT_LARGE)  },
		{ &font.medium, SCALE1(FONT_MEDIUM) },
		{ &font.small,  SCALE1(FONT_SMALL)  },
		{ &font.tiny,   SCALE1(FONT_TINY)   },
	};
	const int n = (int)(sizeof(slots)/sizeof(slots[0]));
	TTF_Font* opened[sizeof(slots)/sizeof(slots[0])];
	for (int i=0; i<n; i++) {
		opened[i] = TTF_OpenFont(LODOR_CJK_FONT_PATH, slots[i].pt);
		if (!opened[i]) { // all-or-nothing: unwind partial opens, keep the stock fonts
			for (int j=0; j<i; j++) TTF_CloseFont(opened[j]);
			LOG_warn("cjk.ttf present but pt %d failed to open; keeping stock fonts\n", slots[i].pt);
			return;
		}
	}
	for (int i=0; i<n; i++) {
		TTF_SetFontStyle(opened[i], TTF_STYLE_BOLD); // match the stock UI weight
		if (*slots[i].slot) TTF_CloseFont(*slots[i].slot);
		*slots[i].slot = opened[i];
	}
	LOG_info("UI fonts swapped to %s\n", LODOR_CJK_FONT_PATH);
}

int main (int argc, char *argv[]) {
	// LOG_info("time from launch to:\n");
	// unsigned long main_begin = SDL_GetTicks();
	// unsigned long first_draw = 0;
	
	if (autoResume()) return 0; // nothing to do
	
	simple_mode = exists(SIMPLE_MODE_PATH);

	LOG_info("MinUI\n");
	InitSettings();
	
	SDL_Surface* screen = GFX_init(MODE_MAIN);
	// LOG_info("- graphics init: %lu\n", SDL_GetTicks() - main_begin);
	Lodor_applyCJKFont(); // §CJK: swap in a CJK-capable UI font if the user dropped one
	Lodor_artInit();      // §artcache (#148): start the off-UI-thread cover-decode worker

	PAD_init();
	// LOG_info("- input init: %lu\n", SDL_GetTicks() - main_begin);
	
	PWR_init();
	if (!HAS_POWER_BUTTON && !simple_mode) PWR_disableSleep();
	// LOG_info("- power init: %lu\n", SDL_GetTicks() - main_begin);
	
	SDL_Surface* version = NULL;
	
	Menu_init();
	// LOG_info("- menu init: %lu\n", SDL_GetTicks() - main_begin);

	// lodor: load the per-system quality-dots preference once at boot (opt-in, default OFF)
	// so the file browser honors it from the first frame — not only after Settings is opened.
	lodor_quality_dots = Lodor_readQualityDots();
	// lodor MULTI-USER: load the badge toggle + active profile label once at boot so the
	// corner badge is correct from the first frame.
	lodor_user_badge = Lodor_readUserBadge();
	lodor_box_art = Lodor_readBoxArt();
	// FIX 3 (#99): decide ONCE whether this platform may run the background cover-fetch
	// feature. Gated OFF on the 128MB miyoomini (weakest tier); ON everywhere else.
	lodor_bg_covers_ok = (strcmp(PLATFORM, "miyoomini") != 0);
	Lodor_readActiveProfile(lodor_profile_label, sizeof(lodor_profile_label));

	// lodor: BOOT-GATE. A fresh, config-less device (no usable {root_uri, token,
	// device_id} triple in config.json) enters the onboarding wizard instead of the
	// library. A connected device skips straight to the menu. The "Re-connect RomM"
	// Sync entry re-runs this later by setting lodor_show_onboard again.
	if (!Lodor_isConnected()) {
		Lodor_resetOnboard();
		lodor_show_onboard = 1;
	}

	// now that (most of) the heavy lifting is done, take a load off
	PWR_setCPUSpeed(CPU_SPEED_MENU);
	GFX_setVsync(VSYNC_STRICT);

	PAD_reset();
	int dirty = 1;
	int show_version = 0;
	int show_setting = 0; // 1=brightness,2=volume
	int was_online = PLAT_isOnline();
	
	// LOG_info("- loop start: %lu\n", SDL_GetTicks() - main_begin);
	while (!quit) {
		GFX_startFrame();
		unsigned long now = SDL_GetTicks();
		
		PAD_poll();
			
		int selected = top->selected;
		int total = top->entries->count;
		
		PWR_update(&dirty, &show_setting, NULL, NULL);

		// lodor §toast: expire toasts and keep repainting while one is visible (plus one
		// frame after the last expires, to clear it). Cheap — only active for the toast lifetime.
		{
			int _toast_now = Lodor_toastTick();
			if (_toast_now || lodor_toast_was_active) dirty = 1;
			lodor_toast_was_active = _toast_now;
		}
		if (Lodor_artPollReady()) dirty = 1; // §artcache (#148): a cover finished decoding -> repaint

		// lodor §4 [#40]: keep the display awake for the WHOLE onboarding flow. The 30s autosleep
		// timer (PWR_update -> SLEEP_DELAY) blanks the panel after an error/prompt screen, hiding
		// what the user needs to act on. Suppress autosleep while the wizard owns the screen and
		// restore normal sleep behavior the instant we drop back to the library. Edge-triggered so
		// we only toggle on transitions (never fight any other autosleep owner frame-to-frame).
		{
			static int lodor_sleep_held = -1; // -1 = uninit, 0 = normal, 1 = suppressed
			// Hold autosleep off while the onboarding wizard owns the screen, OR during the
			// 15s post-task grace window (lodor_keepawake_until) — a long no-input task leaves
			// the idle timer stale, which would otherwise blank the panel the instant it returns.
			int in_grace = lodor_keepawake_until && (int32_t)(lodor_keepawake_until - (uint32_t)now) > 0;
			int want_hold = (lodor_show_onboard || in_grace) ? 1 : 0;
			if (want_hold != lodor_sleep_held) {
				if (want_hold) PWR_disableAutosleep();
				else           PWR_enableAutosleep();
				lodor_sleep_held = want_hold;
			}
		}

		int is_online = PLAT_isOnline();
		if (was_online!=is_online) dirty = 1;
		was_online = is_online;
		
		// lodor: native modal input — these take priority over and block the main menu,
		// exactly like show_version. Order: confirm > details > saves > actions > version > main.
		if (lodor_show_confirm) {
			if (PAD_justPressed(BTN_A)) {
				lodor_show_confirm = 0;
				if (lodor_confirm_kind==1) { // delete: remove file then recreate a 0-byte cloud stub
					remove(lodor_rompath);
					FILE* sf2 = fopen(lodor_rompath, "w"); if (sf2) fclose(sf2);
					lodor_show_actions = 0;
					Lodor_freeActions();
				}
				else if (lodor_confirm_kind==2) { // restore a server save
					char q1[MAX_PATH*2], cmd[MAX_PATH*3], out[256];
					Lodor_shq(lodor_rompath, q1, sizeof(q1));
					snprintf(cmd, sizeof(cmd), "'%s%s' --restore-save '%s' %s",
						SDCARD_PATH, LODOR_ROMM_BIN, q1, lodor_confirm_saveid);
					Lodor_runWithProgress(screen, "Flashing back...", cmd, out, sizeof(out));
					int restored = 0, staged = 0;
					{ char* r = strstr(out, "restored="); if (r) restored = atoi(r+9); }
					// staged=N: the current save couldn't reach the server right now (offline), so
					// N copies were parked to upload on the next sync. The flashback still happened.
					{ char* r = strstr(out, "staged="); if (r) staged = atoi(r+7); }
					lodor_show_saves = 0; Lodor_freeSaves();
					lodor_show_actions = 0; Lodor_freeActions();
					if (restored) {
						// Flashing back to a point means you want to PLAY from there — launch the game
						// straight into the restored save instead of dumping back to the menu. Brief
						// non-blocking toast (no input wait), then hand off to MinUI via Entry_open.
						char done[256];
						const char* when = lodor_confirm_savewhen[0]?lodor_confirm_savewhen:"that point";
						if (staged > 0)
							snprintf(done, sizeof(done), "Flashed back to %s.\nOffline - previous save uploads next sync.\nLaunching...", when);
						else
							snprintf(done, sizeof(done), "Flashed back to %s.\nLaunching...", when);
						Lodor_drawMessage(screen, done);
						SDL_Delay(1100);
						Entry* fe = Entry_new(lodor_rompath, ENTRY_ROM);
						Entry_open(fe);   // writes /tmp/next + sets quit=1; MinUI runs the game next
					} else if (!strstr(out, "restored=")) {
						// No RESULT line at all => the engine never ran (WiFi gate failed). Say THAT,
						// not "the save failed" — a transient WiFi blip is a "try again", not a real
						// restore error. This is the "had to try twice" case made honest.
						Lodor_inlineAck(screen, "Couldn't reach RomM.\nWi-Fi may be down - try again.");
					} else {
						Lodor_inlineAck(screen, "Couldn't flash back to that save");
					}
				}
				else if (lodor_confirm_kind==3) { // dismiss the pending-saves reminder (clear the file)
					char pp[MAX_PATH];
					snprintf(pp, sizeof(pp), "%s/Tools/%s/Lodor.pak/pending-saves.txt", SDCARD_PATH, PLATFORM);
					FILE* tf = fopen(pp, "w"); if (tf) fclose(tf); // truncate to empty -> banner gone next root load
				}
				lodor_confirm_kind = 0;
				dirty = 1;
			}
			else if (PAD_justPressed(BTN_B)) {
				lodor_show_confirm = 0; lodor_confirm_kind = 0; dirty = 1;
			}
		}
		else if (lodor_show_details) {
			if (PAD_justPressed(BTN_B) || PAD_justPressed(BTN_A)) {
				lodor_show_details = 0; dirty = 1;
			}
		}
		else if (lodor_show_saves) {
			int sc = lodor_saves_items ? lodor_saves_items->count : 0;
			if (PAD_justRepeated(BTN_UP)) {
				if (sc>0) { lodor_saves_sel = (lodor_saves_sel-1+sc)%sc; dirty = 1; }
			}
			else if (PAD_justRepeated(BTN_DOWN)) {
				if (sc>0) { lodor_saves_sel = (lodor_saves_sel+1)%sc; dirty = 1; }
			}
			else if (PAD_justPressed(BTN_A)) {
				if (sc>0 && lodor_saves_sel>=0 && lodor_saves_sel<sc) {
					Entry* sv = lodor_saves_items->items[lodor_saves_sel];
					strncpy(lodor_confirm_saveid, sv->path, sizeof(lodor_confirm_saveid)-1);
					lodor_confirm_saveid[sizeof(lodor_confirm_saveid)-1]='\0';
					// label is "<when>  <device>" (double-space delimited); split it back out for the
					// flashback confirm: field 1 = when (relative age or date), field 2 = device.
					{
						strncpy(lodor_confirm_savedev, "another device", sizeof(lodor_confirm_savedev)-1);
						lodor_confirm_savedev[sizeof(lodor_confirm_savedev)-1]='\0';
						strncpy(lodor_confirm_savewhen, "a saved point", sizeof(lodor_confirm_savewhen)-1);
						lodor_confirm_savewhen[sizeof(lodor_confirm_savewhen)-1]='\0';
						const char* L = sv->name ? sv->name : "";
						const char* d = strstr(L, "  ");
						if (d) {
							int wn = (int)(d - L); // when = everything before the first double-space
							if (wn > 0 && wn < (int)sizeof(lodor_confirm_savewhen)) {
								memcpy(lodor_confirm_savewhen, L, wn); lodor_confirm_savewhen[wn]='\0';
							}
							d += 2;
							const char* e = strstr(d, "  ");
							int n = e ? (int)(e-d) : (int)strlen(d);
							if (n > 0 && n < (int)sizeof(lodor_confirm_savedev)) {
								memcpy(lodor_confirm_savedev, d, n); lodor_confirm_savedev[n]='\0';
							}
						}
					}
					lodor_confirm_kind = 2; // restore
					lodor_show_confirm = 1;
					dirty = 1;
				}
			}
			else if (PAD_justPressed(BTN_B)) {
				lodor_show_saves = 0; Lodor_freeSaves(); dirty = 1;
			}
		}
		else if (lodor_show_feed) {
			// lodor: read-only Sync Feed list — scroll only, B closes.
			int fc = lodor_feed_items ? lodor_feed_items->count : 0;
			if (PAD_justRepeated(BTN_UP)) {
				if (fc>0) { lodor_feed_sel = (lodor_feed_sel-1+fc)%fc; dirty = 1; }
			}
			else if (PAD_justRepeated(BTN_DOWN)) {
				if (fc>0) { lodor_feed_sel = (lodor_feed_sel+1)%fc; dirty = 1; }
			}
			else if (PAD_justPressed(BTN_B)) {
				lodor_show_feed = 0; Lodor_freeFeed(); dirty = 1;
			}
		}
		else if (lodor_show_sync) {
			// lodor: ROUTINE Sync front-door (Sync Now / Download Queue / Refresh Library /
			// Download BIOS / Sync Feed). Settings (Keep-WiFi-warm, Re-connect RomM,
			// RetroAchievements) moved to Tools -> Lodor.
			// 6 base rows (FIX #105 split Refresh Library into Update + Full) + the optional
			// "Refresh box art (background)" row (FIX 3 / #99), present only when this platform may
			// run the bg cover-fetch (mirrors the menu build above).
			#define LODOR_SYNC_COUNT (lodor_bg_covers_ok ? 7 : 6)
			if (PAD_justRepeated(BTN_UP)) {
				lodor_sync_sel = (lodor_sync_sel-1+LODOR_SYNC_COUNT)%LODOR_SYNC_COUNT; dirty = 1;
			}
			else if (PAD_justRepeated(BTN_DOWN)) {
				lodor_sync_sel = (lodor_sync_sel+1)%LODOR_SYNC_COUNT; dirty = 1;
			}
			else if (PAD_justPressed(BTN_B)) {
				lodor_show_sync = 0; dirty = 1;
			}
			else if (PAD_justPressed(BTN_A)) {
				char cmd[MAX_PATH*3];
				if (lodor_sync_sel==0) { // Sync Now: upload saves -> refresh Continue (FAST -- no library/collections work)
					int pushed = -1, stuck = 0;
					char stuckwhy[256] = "";
					char pout[2048];
					// 1. Upload pending saves — honest NAMED step (not a vague "Syncing...").
					snprintf(cmd, sizeof(cmd), "'%s%s' --push-pending", SDCARD_PATH, LODOR_ROMM_BIN);
					Lodor_runWithProgress(screen, "Uploading saves...", cmd, pout, sizeof(pout));
					{ char* ln = pout; while (ln && *ln) {
						int n,m,k; char g[160], w[160];
						if (sscanf(ln, "RESULT pushed=%d total=%d stuck=%d", &n,&m,&k)==3) { pushed=n; stuck=k; }
						else if (!stuckwhy[0] && sscanf(ln, "STUCK\t%159[^\t]\t%159[^\r\n]", g, w)==2)
							snprintf(stuckwhy, sizeof(stuckwhy), "%s:\n%s", g, w);
						char* nx = strchr(ln, '\n'); ln = nx ? nx+1 : NULL; } }
					// Collections refresh removed from Sync Now (moved to Refresh Library) -- was the slow step.
					// 3. Refresh the Continue tile (most-recent game across devices); keep last-good on a miss.
					Lodor_drawMessage(screen, "Updating Continue...");
					snprintf(cmd, sizeof(cmd),
						"o=$('%s%s' --recent 2>/dev/null); [ -n \"$o\" ] && printf '%%s\\n' \"$o\" > '%s/Tools/%s/Lodor.pak/recent.txt'",
						SDCARD_PATH, LODOR_ROMM_BIN, SDCARD_PATH, PLATFORM);
					system(cmd);
					Lodor_refreshContinue(); // reflect the new recent.txt in the tile right now
					// 4. Honest summary — if anything is stuck, NAME why.
					if (stuck > 0) {
						char sm[320];
						snprintf(sm, sizeof(sm), "%d save%s couldn't upload --\n%s", stuck, stuck==1?"":"s", stuckwhy[0]?stuckwhy:"see logs");
						Lodor_drawMessage(screen, sm); SDL_Delay(2800);
					} else if (pushed == 0) {
						// engine ran, nothing was pending -> honest no-op feedback (not a fake "synced").
						Lodor_drawMessage(screen, "Nothing to sync"); SDL_Delay(1200);
					} else if (pushed > 0) {
						char m2[64]; snprintf(m2, sizeof(m2), "Synced -- %d save%s uploaded", pushed, pushed==1?"":"s");
						Lodor_drawMessage(screen, m2); SDL_Delay(1400);
					} else {
						// pushed<0 + stuck==0 => push-pending printed NO RESULT => the engine never ran
						// (Wi-Fi down / unreachable). HONEST failure, never a fake "complete".
						Lodor_drawMessage(screen, "Couldn't reach RomM --\nsaves still pending"); SDL_Delay(2200);
					}
					lodor_keepawake_until = SDL_GetTicks() + 15000; // 15s from the sync's END, not mid-run
					dirty = 1;
				}
				else if (lodor_sync_sel==1) { // Download Queue: fetch every queued ROM over Wi-Fi
					int qn = Lodor_queueCount();
					if (qn==0) {
						// honest no-op: the badge already reads (0), say so plainly.
						Lodor_drawMessage(screen, "Download queue empty");
						SDL_Delay(1200);
						dirty = 1;
					} else {
						// reuse the download-on-launch progress overlay: the engine streams
						// /tmp/dl-progress + /tmp/romm-phase per file, dropping landed entries and
						// keeping failures in download-queue.txt for retry. NO fake progress.
						int dl=-1, fail=0, rem=-1;
						char qout[1024];
						snprintf(cmd, sizeof(cmd), "'%s%s' --download-queue", SDCARD_PATH, LODOR_ROMM_BIN);
						Lodor_runWithProgress(screen, "Downloading queue...", cmd, qout, sizeof(qout));
						{ char* ln = qout; while (ln && *ln) {
							int a,b,c; if (sscanf(ln, "RESULT downloaded=%d failed=%d remaining=%d", &a,&b,&c)==3) { dl=a; fail=b; rem=c; }
							char* nx = strchr(ln, '\n'); ln = nx ? nx+1 : NULL; } }
						if (dl < 0) {
							// no RESULT line parsed -> engine never produced output (Wi-Fi down /
							// unreachable). HONEST failure; the queue is left untouched for retry.
							Lodor_drawMessage(screen, "Couldn't reach RomM --\nqueue unchanged");
							SDL_Delay(2200);
						} else if (fail > 0) {
							char m2[96];
							snprintf(m2, sizeof(m2), "Downloaded %d, %d failed --\n%d still queued", dl, fail, rem<0?0:rem);
							Lodor_drawMessage(screen, m2); SDL_Delay(2600);
						} else {
							char m2[64];
							snprintf(m2, sizeof(m2), "Downloaded %d game%s", dl, dl==1?"":"s");
							Lodor_drawMessage(screen, m2); SDL_Delay(1600);
						}
						lodor_keepawake_until = SDL_GetTicks() + 15000;
						dirty = 1; // refresh the menu (badge count + any newly-present stubs)
					}
				}
				else if (lodor_sync_sel==2 || lodor_sync_sel==3) { // Refresh Library: regenerate stubs + Collections
					// FIX #105: two flavors share this handler —
					//   sel==2 "Update" -> --mirror-catalog        (fast: only new games + missing covers)
					//   sel==3 "Full"   -> --mirror-catalog --full (re-fetch EVERY cover)
					// lodor: a first full mirror of 6,000+ games takes minutes. Route it
					// through Lodor_runWithProgress so the engine's real side-channel progress
					// (/tmp/dl-progress + /tmp/romm-phase: "Mirroring <platform> (i/N)") drives
					// a live % bar instead of a frozen "Refreshing..." screen. NO >/dev/null
					// here: the wrapper captures stdout to parse the MIRROR RESULT line.
					int lodor_full = (lodor_sync_sel==3);
					char mout[1024];
					int created = -1;
					snprintf(cmd, sizeof(cmd), "'%s%s' --mirror-catalog%s",
						SDCARD_PATH, LODOR_ROMM_BIN, lodor_full ? " --full" : "");
					Lodor_runWithProgress(screen, lodor_full ? "Refreshing all covers..." : "Refreshing library...", cmd, mout, sizeof(mout));
					{ char* ln = mout; while (ln && *ln) {
						int c,e,s,m; if (sscanf(ln, "MIRROR created=%d existing=%d skipped=%d multifile=%d", &c,&e,&s,&m)==4) { created=c; }
						char* nx = strchr(ln, '\n'); ln = nx ? nx+1 : NULL; } }
					if (created < 0) {
						// No MIRROR line parsed -> the mirror failed (exit 3 / couldn't reach
						// RomM). Show the honest error; skip Collections (no point).
						Lodor_drawMessage(screen, "Couldn't reach RomM");
						SDL_Delay(1500);
						dirty = 1;
					} else {
						// Collections is quick; still show the bar so the screen isn't frozen.
						snprintf(cmd, sizeof(cmd), "'%s%s' --mirror-collections",
							SDCARD_PATH, LODOR_ROMM_BIN);
						Lodor_runWithProgress(screen, "Updating collections...", cmd, mout, sizeof(mout));
						// Refresh the Continue tile (most-recent across devices); keep last-good on a miss.
						Lodor_drawMessage(screen, "Updating Continue...");
						snprintf(cmd, sizeof(cmd),
							"o=$('%s%s' --recent 2>/dev/null); [ -n \"$o\" ] && printf '%%s\\n' \"$o\" > '%s/Tools/%s/Lodor.pak/recent.txt'",
							SDCARD_PATH, LODOR_ROMM_BIN, SDCARD_PATH, PLATFORM);
						system(cmd);
						Lodor_refreshContinue(); // reflect the new recent.txt in the tile
						char msg[64];
						snprintf(msg, sizeof(msg), "Library updated -- %d new", created);
						Lodor_drawMessage(screen, msg);
						SDL_Delay(1500);
						lodor_keepawake_until = SDL_GetTicks() + 15000; // 15s from the refresh's END
						// FIX 3 (#104): re-scan the current directory in place so newly-created
						// Roms/<System (TAG)> folders (NDS, PSP, ...) appear WITHOUT a reboot. Only
						// meaningful at the system root, but harmless (and selection-preserving)
						// anywhere — Lodor_rescanTop re-reads the same path either way.
						Lodor_rescanTop();
						// Refresh the on-screen library in place so the new stubs appear.
						dirty = 1;
					}
				}
				else if (lodor_sync_sel==4) { // Download BIOS
					int bios = -1;
					char bout[1024];
					snprintf(cmd, sizeof(cmd), "'%s%s' --download-bios",
						SDCARD_PATH, LODOR_ROMM_BIN);
					Lodor_runWithProgress(screen, "Downloading BIOS...", cmd, bout, sizeof(bout));
					{ char* ln = bout; while (ln && *ln) {
						int n; if (sscanf(ln, "RESULT bios=%d", &n)==1) { bios=n; }
						char* nx = strchr(ln, '\n'); ln = nx ? nx+1 : NULL; } }
					if (bios==0) Lodor_drawMessage(screen, "No BIOS to update");
					else if (bios>0) { char m2[64]; snprintf(m2, sizeof(m2), "Downloaded %d BIOS file%s", bios, bios==1?"":"s"); Lodor_drawMessage(screen, m2); }
					else Lodor_drawMessage(screen, "BIOS updated");
					SDL_Delay(1200);
					dirty = 1;
				}
				else if (lodor_sync_sel==5) { // Sync Feed: recent server saves, read-only list
					// lodor: let the progress wrapper's own stdout->/tmp/romm-out redirect capture the
					// feed (no double-redirect), then write it to the file Lodor_buildFeed reads.
					char fout[4096];
					snprintf(cmd, sizeof(cmd), "'%s%s' --sync-feed",
						SDCARD_PATH, LODOR_ROMM_BIN);
					Lodor_runWithProgress(screen, "Loading feed...", cmd, fout, sizeof(fout));
					{ FILE* fw = fopen("/tmp/lodor-feed.txt", "w");
					  if (fw) { fputs(fout, fw); fclose(fw); } }
					Lodor_buildFeed();
					lodor_show_sync = 0; // hand off to the feed list (render shows empty state if none)
					lodor_show_feed = 1; lodor_feed_sel = 0;
					dirty = 1;
				}
				else if (lodor_bg_covers_ok && lodor_sync_sel==6) { // FIX 3 (#99): Refresh box art (background)
					// Spawn the DETACHED bg cover-fetch daemon (model on romm-syncd): it owns the WiFi
					// shell lock, warms covers for Recently-Played + active Collections only, writes
					// bg-task.status (which the upper-right pill reflects), and yields to games. setsid +
					// background + </dev/null so it survives this menu closing and never blocks the UI.
					// Idempotent: the worker's own pidfile makes a second trigger a no-op.
					char bg[MAX_PATH];
					snprintf(bg, sizeof(bg), "setsid '%s/Tools/%s/Lodor.pak/bin/lodor-bg-covers' >/dev/null 2>&1 </dev/null &",
						SDCARD_PATH, PLATFORM);
					system(bg);
					Lodor_drawMessage(screen, "Refreshing box art in the background...");
					SDL_Delay(1200);
					lodor_show_sync = 0; // back to the library so the upper-right pill is visible
					dirty = 1;
				}
			}
			#undef LODOR_SYNC_COUNT
		}
		else if (lodor_show_settings) {
			// lodor TWO-MENU model: Lodor/RomM SETTINGS (under Tools -> Lodor).
			// Rows: Re-connect RomM / Box Art options / Keep WiFi warm / Quality dots /
			//       Switch Profile (MULTI-USER) / User badge (MULTI-USER) / RetroAchievements.
			#define LODOR_SETTINGS_COUNT 7
			if (PAD_justRepeated(BTN_UP)) {
				lodor_settings_sel = (lodor_settings_sel-1+LODOR_SETTINGS_COUNT)%LODOR_SETTINGS_COUNT; dirty = 1;
			}
			else if (PAD_justRepeated(BTN_DOWN)) {
				lodor_settings_sel = (lodor_settings_sel+1)%LODOR_SETTINGS_COUNT; dirty = 1;
			}
			else if (PAD_justPressed(BTN_B)) {
				lodor_show_settings = 0; dirty = 1;
			}
			else if (PAD_justPressed(BTN_A)) {
				if (lodor_settings_sel==0) { // Re-connect RomM: re-run the onboarding wizard (re-auth / re-pair)
					lodor_show_settings = 0;
					Lodor_prefillOnboard(); // edit, not retype: seed from the existing config (non-secret fields only)
					lodor_show_onboard = 1;
					dirty = 1;
				}
				else if (lodor_settings_sel==1) { // Box art: toggle RomM cover download (#96, pure file I/O)
					int warm, grace; Lodor_readWifiWarm(&warm, &grace);
					lodor_box_art = lodor_box_art ? 0 : 1;
					Lodor_writeSettings(warm, grace, lodor_quality_dots, lodor_user_badge, lodor_box_art);
					dirty = 1;
				}
				else if (lodor_settings_sel==2) { // Keep WiFi warm toggle (pure file I/O)
					int warm, grace; Lodor_readWifiWarm(&warm, &grace);
					warm = warm ? 0 : 1;
					Lodor_writeSettings(warm, grace, lodor_quality_dots, lodor_user_badge, lodor_box_art);
					lodor_wifi_warm = warm;
					dirty = 1;
				}
				else if (lodor_settings_sel==3) { // Show quality dots toggle (pure file I/O)
					int warm, grace; Lodor_readWifiWarm(&warm, &grace);
					lodor_quality_dots = lodor_quality_dots ? 0 : 1;
					Lodor_writeSettings(warm, grace, lodor_quality_dots, lodor_user_badge, lodor_box_art);
					dirty = 1;
				}
				else if (lodor_settings_sel==4) { // MULTI-USER: Switch Profile -> open the profile switcher
					Lodor_readActiveProfile(lodor_profile_label, sizeof(lodor_profile_label));
					Lodor_buildProfiles();
					lodor_show_settings = 0;
					lodor_show_profiles = 1; lodor_profiles_sel = 0;
					dirty = 1;
				}
				else if (lodor_settings_sel==5) { // MULTI-USER: User badge toggle (pure file I/O, no clobber)
					int warm, grace; Lodor_readWifiWarm(&warm, &grace);
					lodor_user_badge = lodor_user_badge ? 0 : 1;
					Lodor_writeSettings(warm, grace, lodor_quality_dots, lodor_user_badge, lodor_box_art);
					dirty = 1;
				}
				else if (lodor_settings_sel==6) { // RetroAchievements: hand off to the native RA overlay
					lodor_show_settings = 0;
					Lodor_readRAUser(lodor_ra_status, sizeof(lodor_ra_status)); // "Logged in as <user>" (non-secret)
					lodor_ra_enable   = Lodor_readRAKey("RA_ENABLE", 1);   // load the toggles for the overlay rows
					lodor_ra_hardcore = Lodor_readRAKey("RA_HARDCORE", 0);
					lodor_ra_stage = 0; lodor_ra_sel = 0;
					lodor_show_ra = 1;
					dirty = 1;
				}
			}
			#undef LODOR_SETTINGS_COUNT
		}
		else if (lodor_show_profiles) {
			// lodor MULTI-USER (Switch User): pick an EXISTING RomM user. UP/DOWN scroll;
			// A picks the highlighted user -> already signed in: instant switch (no password);
			// not signed in: straight to the masked password prompt (username is the picked
			// one, never typed). B returns to Settings.
			int pcount = lodor_profile_items ? lodor_profile_items->count : 0;
			if (pcount < 1) pcount = 1;
			if (PAD_justRepeated(BTN_UP)) {
				lodor_profiles_sel = (lodor_profiles_sel-1+pcount)%pcount; dirty = 1;
			}
			else if (PAD_justRepeated(BTN_DOWN)) {
				lodor_profiles_sel = (lodor_profiles_sel+1)%pcount; dirty = 1;
			}
			else if (PAD_justPressed(BTN_B)) {
				lodor_show_profiles = 0;
				lodor_show_settings = 1; lodor_settings_sel = 4;
				dirty = 1;
			}
			else if (PAD_justPressed(BTN_A) && lodor_profile_items && lodor_profiles_sel < lodor_profile_items->count) {
				Entry* e = (Entry*)lodor_profile_items->items[lodor_profiles_sel];
				// path = [signedin flag '0'/'1'][username]. Reject malformed rows.
				if (e->path && (e->path[0]=='0' || e->path[0]=='1') && e->path[1]) {
					int signed_in = (e->path[0]=='1');
					const char* uname = e->path + 1;
					if (signed_in) {
						// Already signed in on this device -> instant switch (write
						// active-profile.txt + rebuild library). NO password.
						int ok = Lodor_writeActiveProfile(screen, uname);
						if (ok) {
							snprintf(lodor_profile_label, sizeof(lodor_profile_label), "%s", uname);
							lodor_user_badge = Lodor_readUserBadge();
							char m[128]; snprintf(m, sizeof(m), "Now playing as\n%s", uname);
							Lodor_drawMessage(screen, m); SDL_Delay(1000);
							lodor_show_profiles = 0;
						} else {
							Lodor_inlineAck(screen, "Couldn't switch user.");
						}
						dirty = 1;
					} else {
						// Not signed in -> sign in with a PAIR CODE (client-token exchange), NOT a
						// password and NOT a typed name. Code keyboard at the PAIR step in profile
						// mode; the PAIR handler routes to --pair-profile and activates the user.
						lodor_show_profiles = 0;
						Lodor_resetOnboard();
						lodor_ob_add_profile = 1;
						snprintf(lodor_ob_login_user, sizeof(lodor_ob_login_user), "%s", uname);
						lodor_ob_code[0] = 0;
						Lodor_obKbOpen(lodor_ob_code, LODOR_OB_CODE_MAX, "Pair code:", 0, 0);
						lodor_onboard_step = LODOR_OB_PAIR;
						lodor_show_onboard = 1;
						dirty = 1;
					}
				}
			}
		}
		else if (lodor_show_ra) {
			// lodor: RetroAchievements overlay input. Three sub-modes:
			//  - keyboard active  -> shared key grid edits lodor_ra_user / lodor_ra_pass
			//  - stage 1/2 + kb closed -> consume the just-finished username / password field
			//  - menu (stage 0)   -> "Log in" opens the username keyboard; B closes the overlay
			if (lodor_ob_kb_active) {
				Lodor_kbInput(&dirty); // identical grid to onboarding (mask handled in the draw path)
			}
			else if (lodor_ra_stage==1) {
				// username keyboard just closed (DONE/START/B)
				if (lodor_ob_kb_cancelled || !lodor_ra_user[0]) {
					lodor_ra_user[0] = '\0'; lodor_ra_stage = 0; dirty = 1; // cancelled / empty -> back to menu
				} else {
					// advance to the masked password field
					lodor_ra_pass[0] = '\0';
					Lodor_obKbOpen(lodor_ra_pass, sizeof(lodor_ra_pass), "RA password:", 0, 0);
					lodor_ob_kb_mask = 1; // echo as '*' (value still edited in clear)
					lodor_ra_stage = 2; dirty = 1;
				}
			}
			else if (lodor_ra_stage==2) {
				// password keyboard just closed
				if (lodor_ob_kb_cancelled || !lodor_ra_pass[0]) {
					lodor_ra_pass[0] = '\0'; lodor_ra_stage = 0; dirty = 1; // cancelled / empty -> back to menu
				} else {
					// Shell the engine login through the shared progress overlay. SECURITY: the
					// password goes via STDIN (never argv) AND is passed to the shell only through
					// an env var, so it appears in neither the literal command nor romm-run/engine
					// argv; Lodor_runWithProgress logs nothing (it backgrounds the cmd and only reads
					// /tmp/romm-done + the RESULT line). Engine prints "RESULT ra_login=<0|1>".
					setenv("LODOR_RA_U", lodor_ra_user, 1);
					setenv("LODOR_RA_P", lodor_ra_pass, 1);
					char cmd[MAX_PATH*3], rout[1024];
					snprintf(cmd, sizeof(cmd),
						"printf '%%s\\n' \"$LODOR_RA_P\" | '%s%s' --ra-login \"$LODOR_RA_U\"",
						SDCARD_PATH, LODOR_ROMM_BIN);
					Lodor_runWithProgress(screen, "Signing in to RetroAchievements...", cmd, rout, sizeof(rout));
					unsetenv("LODOR_RA_P"); unsetenv("LODOR_RA_U");
					int ra_ok = -1;
					{ char* ln = rout; while (ln && *ln) {
						int v; if (sscanf(ln, "RESULT ra_login=%d", &v)==1) ra_ok = v;
						char* nx = strchr(ln, '\n'); ln = nx ? nx+1 : NULL; } }
					lodor_ra_pass[0] = '\0'; // wipe the typed password from memory after use
					if (ra_ok==1) {
						Lodor_readRAUser(lodor_ra_status, sizeof(lodor_ra_status));
						char m2[96]; snprintf(m2, sizeof(m2), "Logged in as %s", lodor_ra_status[0]?lodor_ra_status:lodor_ra_user);
						Lodor_drawMessage(screen, m2); SDL_Delay(1500);
					} else if (ra_ok==0) {
						Lodor_drawMessage(screen, "RetroAchievements login failed --\ncheck your username and password"); SDL_Delay(2200);
					} else {
						// no RESULT line => engine never ran (Wi-Fi down / RA unreachable). Honest.
						Lodor_drawMessage(screen, "Couldn't reach RetroAchievements"); SDL_Delay(2000);
					}
					lodor_ra_stage = 0; dirty = 1;
				}
			}
			else {
				// menu mode: 3 rows — [0] Log in, [1] RetroAchievements ON/OFF, [2] Hardcore ON/OFF.
				if (PAD_justPressed(BTN_B)) {
					lodor_show_ra = 0; lodor_ra_sel = 0; dirty = 1;
				}
				else if (PAD_justRepeated(BTN_UP)) {
					lodor_ra_sel = (lodor_ra_sel-1+LODOR_RA_ROWS)%LODOR_RA_ROWS; dirty = 1;
				}
				else if (PAD_justRepeated(BTN_DOWN)) {
					lodor_ra_sel = (lodor_ra_sel+1)%LODOR_RA_ROWS; dirty = 1;
				}
				else if (PAD_justPressed(BTN_A)) {
					if (lodor_ra_sel==0) { // Log in / Log in again -> username keyboard
						lodor_ra_user[0] = '\0';
						Lodor_obKbOpen(lodor_ra_user, sizeof(lodor_ra_user), "RA username:", 0, 0);
						lodor_ra_stage = 1; dirty = 1;
					}
					else if (lodor_ra_sel==1) { // RetroAchievements ON/OFF (pure file I/O)
						lodor_ra_enable = lodor_ra_enable ? 0 : 1;
						Lodor_writeRASettings(lodor_ra_enable, lodor_ra_hardcore);
						dirty = 1;
					}
					else if (lodor_ra_sel==2) { // Hardcore ON/OFF (pure file I/O)
						lodor_ra_hardcore = lodor_ra_hardcore ? 0 : 1;
						Lodor_writeRASettings(lodor_ra_enable, lodor_ra_hardcore);
						dirty = 1;
					}
				}
			}
		}
		else if (lodor_show_switch) {
			// lodor §gameswitch (#149): LEFT/RIGHT cycles, A resumes, B closes.
			if (PAD_justRepeated(BTN_LEFT) && lodor_switch_count>0) {
				lodor_switch_sel = (lodor_switch_sel-1+lodor_switch_count)%lodor_switch_count;
				dirty = 1;
			}
			else if (PAD_justRepeated(BTN_RIGHT) && lodor_switch_count>0) {
				lodor_switch_sel = (lodor_switch_sel+1)%lodor_switch_count;
				dirty = 1;
			}
			else if (PAD_justPressed(BTN_B)) {
				lodor_show_switch = 0; dirty = 1;
			}
			else if (PAD_justPressed(BTN_A) && lodor_switch_count>0) {
				// resume through the EXISTING machinery: prime can_resume/slot_path for this
				// ROM (readyResumePath), arm should_resume, then ride the normal launch path —
				// Lodor_downloadThenLaunch handles 0-byte cloud stubs (download-with-feedback
				// first) and Entry_open -> openRom honors #144 overrides via Lodor_resolveEmu.
				char lodor_sw_path[MAX_PATH];
				strcpy(lodor_sw_path, lodor_switch_path[lodor_switch_sel]);
				lodor_show_switch = 0;
				readyResumePath(lodor_sw_path, ENTRY_ROM);
				if (can_resume) should_resume = 1;
				Entry* lodor_sw_e = Entry_new(lodor_sw_path, ENTRY_ROM);
				if (!Lodor_downloadThenLaunch(screen, lodor_sw_e, 1))
					should_resume = 0; // download failed, still on the menu — disarm
				Entry_free(lodor_sw_e);
				dirty = 1;
			}
		}
		else if (lodor_show_emupick) {
			// §override (#144): Emulator picker input — same chrome as the actions modal.
			int ec = lodor_emupick_items ? lodor_emupick_items->count : 0;
			if (PAD_justRepeated(BTN_UP)) {
				if (ec>0) { lodor_emupick_sel = (lodor_emupick_sel-1+ec)%ec; dirty = 1; }
			}
			else if (PAD_justRepeated(BTN_DOWN)) {
				if (ec>0) { lodor_emupick_sel = (lodor_emupick_sel+1)%ec; dirty = 1; }
			}
			else if (PAD_justPressed(BTN_B)) {
				lodor_show_emupick = 0; Lodor_freeEmuPick(); dirty = 1;
			}
			else if (PAD_justPressed(BTN_A) && ec>0 && lodor_emupick_sel>=0 && lodor_emupick_sel<ec) {
				Entry* pick = lodor_emupick_items->items[lodor_emupick_sel];
				// row path "" = default (deletes the sidecar); else pak=<stem>
				Lodor_writeEmuSidecar(lodor_rompath, pick->path[0] ? pick->path : NULL);
				lodor_show_emupick = 0; Lodor_freeEmuPick();
				// refresh the "Emulator: ..." row label and keep focus on it
				Lodor_rebuildActions();
				if (lodor_action_items) for (int i=0; i<lodor_action_items->count; i++) {
					Entry* lodor_ai = lodor_action_items->items[i];
					if (strcmp(lodor_ai->path, "emupick")==0) { lodor_action_sel = i; break; }
				}
				dirty = 1;
			}
		}
		else if (lodor_show_actions) {
			int ac = lodor_action_items ? lodor_action_items->count : 0;
			if (PAD_justRepeated(BTN_UP)) {
				if (ac>0) { lodor_action_sel = (lodor_action_sel-1+ac)%ac; dirty = 1; }
			}
			else if (PAD_justRepeated(BTN_DOWN)) {
				if (ac>0) { lodor_action_sel = (lodor_action_sel+1)%ac; dirty = 1; }
			}
			else if (PAD_justPressed(BTN_B)) {
				lodor_show_actions = 0; Lodor_freeActions(); dirty = 1;
			}
			else if (PAD_justPressed(BTN_A) && ac>0 && lodor_action_sel>=0 && lodor_action_sel<ac) {
				Entry* act = lodor_action_items->items[lodor_action_sel];
				char* id = act->path;
				char q1[MAX_PATH*2], cmd[MAX_PATH*3];

				if (strcmp(id,"play")==0) {
					// route through the normal launch path so collection-aware saveLast() runs
					// (B-back from the game returns to the right folder). For a 0-byte stub this
					// downloads with on-screen feedback first, then launches; on-device launches now.
					if (lodor_actions_from_search) {
						// opened from a search result: the real entry is lodor_rompath, not top->selected.
						// A launch closes the search overlay so we never land back on a stale search.
						Entry* lodor_real = Entry_new(lodor_rompath, ENTRY_ROM);
						lodor_show_actions = 0; lodor_actions_from_search = 0; Lodor_freeActions();
						Lodor_closeSearch();
						Lodor_downloadThenLaunch(screen, lodor_real, 1);
						Entry_free(lodor_real);
					} else {
						Entry* lodor_real = top->entries->items[top->selected];
						lodor_show_actions = 0; Lodor_freeActions();
						Lodor_downloadThenLaunch(screen, lodor_real, 1);
					}
					dirty = 1;
				}
				else if (strcmp(id,"download")==0) {
					// download-now: same feedback flow as launch, but return to the menu afterward.
					if (lodor_actions_from_search) {
						// downloaded item came from a search result: pull via lodor_rompath, then
						// close the search overlay (the stub is now a real file on the card).
						Entry* lodor_real = Entry_new(lodor_rompath, ENTRY_ROM);
						lodor_show_actions = 0; lodor_actions_from_search = 0; Lodor_freeActions();
						Lodor_closeSearch();
						Lodor_downloadThenLaunch(screen, lodor_real, 0);
						Entry_free(lodor_real);
					} else {
						Entry* lodor_real = top->entries->items[top->selected];
						lodor_show_actions = 0; Lodor_freeActions();
						Lodor_downloadThenLaunch(screen, lodor_real, 0);
					}
					dirty = 1;
				}
				else if (strcmp(id,"queue")==0) {
					Lodor_queueDownload(lodor_rompath); // no WiFi needed, just append to the queue file
					lodor_show_actions = 0; Lodor_freeActions();
					dirty = 1;
				}
				else if (strcmp(id,"syncsave")==0) {
					Lodor_shq(lodor_rompath, q1, sizeof(q1));
					snprintf(cmd, sizeof(cmd), "'%s%s' --sync-save '%s'", SDCARD_PATH, LODOR_ROMM_BIN, q1);
					Lodor_runWithProgress(screen, "Syncing save...", cmd, NULL, 0);
					lodor_show_actions = 0; Lodor_freeActions();
					dirty = 1;
				}
				else if (strcmp(id,"serversaves")==0) {
					Lodor_shq(lodor_rompath, q1, sizeof(q1));
					char cache[MAX_PATH]; static char shc[4096];
					Lodor_savesCachePath(lodor_rompath, cache, sizeof(cache));
					{ char dir[MAX_PATH]; snprintf(dir,sizeof(dir),"%s/Tools/%s/Lodor.pak/.saves-cache",SDCARD_PATH,PLATFORM); mkdir(dir,0755); }
					if (access(cache, R_OK)==0) {
						// CACHE-FIRST: show the cached timeline INSTANTLY (no server wait)...
						snprintf(shc,sizeof(shc),"cp '%s' /tmp/lodor-saves.txt 2>/dev/null", cache);
						system(shc);
						Lodor_buildSaves();
						// ...then refresh the cache in the BACKGROUND for next time. The [ -s ] guard means a
						// failed/offline fetch (empty output) NEVER wipes the readable cache.
						snprintf(shc,sizeof(shc),
							"( '%s%s' --list-saves '%s' > '%s.new' 2>/dev/null; [ -s '%s.new' ] && mv '%s.new' '%s' || rm -f '%s.new' ) &",
							SDCARD_PATH, LODOR_ROMM_BIN, q1, cache, cache, cache, cache, cache);
						system(shc);
					} else {
						// First open for this game: one live fetch, then seed the cache.
						Lodor_drawMessage(screen, "Loading save points...");
						snprintf(shc,sizeof(shc),"'%s%s' --list-saves '%s' > /tmp/lodor-saves.txt 2>/dev/null", SDCARD_PATH, LODOR_ROMM_BIN, q1);
						system(shc);
						Lodor_buildSaves();
						snprintf(shc,sizeof(shc),"[ -s /tmp/lodor-saves.txt ] && cp /tmp/lodor-saves.txt '%s' 2>/dev/null", cache);
						system(shc);
					}
					lodor_show_saves = 1;
					dirty = 1;
				}
				else if (strcmp(id,"delete")==0) {
					lodor_confirm_kind = 1; // delete
					lodor_show_confirm = 1;
					dirty = 1;
				}
				else if (strcmp(id,"emupick")==0) {
					// §override (#144): open the Emulator picker over the actions modal
					Lodor_buildEmuPick(lodor_rompath);
					lodor_show_emupick = 1;
					dirty = 1;
				}
				else if (strcmp(id,"details")==0) {
					lodor_show_details = 1;
					dirty = 1;
				}
			}
		}
		else if (lodor_show_search) {
			// lodor: LIBRARY SEARCH input. Phase 0 = keyboard, phase 1 = results.
			if (lodor_search_phase==0) {
				if (PAD_justRepeated(BTN_UP)) {
					lodor_kb_row = (lodor_kb_row-1+LODOR_KB_ROWS)%LODOR_KB_ROWS;
					if (lodor_kb_row==LODOR_KB_ROWS-1) Lodor_kbSnapSpecial();
					dirty = 1;
				}
				else if (PAD_justRepeated(BTN_DOWN)) {
					lodor_kb_row = (lodor_kb_row+1)%LODOR_KB_ROWS;
					if (lodor_kb_row==LODOR_KB_ROWS-1) Lodor_kbSnapSpecial();
					dirty = 1;
				}
				else if (PAD_justRepeated(BTN_LEFT)) {
					if (lodor_kb_row==LODOR_KB_ROWS-1) {
						int order[3] = { LODOR_KB_GO_COL, LODOR_KB_DEL_COL, LODOR_KB_SPACE_COL };
						for (int i=0;i<3;i++) if (lodor_kb_col==order[i]) { lodor_kb_col = order[(i+1)%3]; break; }
					} else {
						lodor_kb_col = (lodor_kb_col-1+LODOR_KB_COLS)%LODOR_KB_COLS;
					}
					dirty = 1;
				}
				else if (PAD_justRepeated(BTN_RIGHT)) {
					if (lodor_kb_row==LODOR_KB_ROWS-1) {
						int order[3] = { LODOR_KB_SPACE_COL, LODOR_KB_DEL_COL, LODOR_KB_GO_COL };
						for (int i=0;i<3;i++) if (lodor_kb_col==order[i]) { lodor_kb_col = order[(i+1)%3]; break; }
					} else {
						lodor_kb_col = (lodor_kb_col+1)%LODOR_KB_COLS;
					}
					dirty = 1;
				}
				else if (PAD_justPressed(BTN_L1)) { lodor_kb_layer = (lodor_kb_layer-1+LODOR_KB_LAYERS)%LODOR_KB_LAYERS; dirty = 1; } // #97: cycle abc <- ABC <- 123
				else if (PAD_justPressed(BTN_R1)) { lodor_kb_layer = (lodor_kb_layer+1)%LODOR_KB_LAYERS; dirty = 1; } // #97: cycle abc -> ABC -> 123
				else if (PAD_justPressed(BTN_A)) {
					int len = strlen(lodor_search_q);
					if (lodor_kb_row < 4) {
						if (len < LODOR_SEARCH_QMAX-1) {
							lodor_search_q[len] = LODOR_KB_CH(lodor_kb_row, lodor_kb_col);
							lodor_search_q[len+1] = '\0';
						}
					}
					else if (lodor_kb_col==LODOR_KB_SPACE_COL) {
						if (len < LODOR_SEARCH_QMAX-1) { lodor_search_q[len]=' '; lodor_search_q[len+1]='\0'; }
					}
					else if (lodor_kb_col==LODOR_KB_DEL_COL) {
						if (len > 0) lodor_search_q[len-1] = '\0';
					}
					else if (lodor_kb_col==LODOR_KB_GO_COL) {
						if (len >= 1) {
							Lodor_drawMessage(screen, "Searching...");
							Lodor_runScan();
							lodor_search_phase = 1;
						}
					}
					dirty = 1;
				}
				else if (PAD_justPressed(BTN_START)) {
					// START = submit search, same as pressing the on-screen [SEARCH] key.
					if (strlen(lodor_search_q) >= 1) {
						Lodor_drawMessage(screen, "Searching...");
						Lodor_runScan();
						lodor_search_phase = 1;
					}
					dirty = 1;
				}
				else if (PAD_justPressed(BTN_B)) {
					Lodor_closeSearch(); dirty = 1; // B from keyboard closes the overlay
				}
			}
			else { // phase 1: results list
				int rc = lodor_search_results ? lodor_search_results->count : 0;
				if (PAD_justRepeated(BTN_UP)) {
					if (rc>0) {
						lodor_search_sel -= 1;
						if (lodor_search_sel<0) {
							lodor_search_sel = rc-1;
							int s = rc - (MAIN_ROW_COUNT-1);
							lodor_search_start = (s<0)?0:s;
							lodor_search_end = rc;
						} else if (lodor_search_sel < lodor_search_start) {
							lodor_search_start -= 1; lodor_search_end -= 1;
						}
						dirty = 1;
					}
				}
				else if (PAD_justRepeated(BTN_DOWN)) {
					if (rc>0) {
						lodor_search_sel += 1;
						if (lodor_search_sel>=rc) {
							lodor_search_sel = 0;
							lodor_search_start = 0;
							lodor_search_end = (rc<(MAIN_ROW_COUNT-1))?rc:(MAIN_ROW_COUNT-1);
						} else if (lodor_search_sel >= lodor_search_end) {
							lodor_search_start += 1; lodor_search_end += 1;
						}
						dirty = 1;
					}
				}
				else if (PAD_justPressed(BTN_A) && rc>0 && lodor_search_sel>=0 && lodor_search_sel<rc) {
					// Take ownership of the selected Entry by dup'ing what we need BEFORE freeing
					// the results array, so the launch path never touches freed memory.
					Entry* sel = lodor_search_results->items[lodor_search_sel];
					Entry* launch = Entry_new(sel->path, ENTRY_ROM);
					Lodor_closeSearch(); // frees lodor_search_results (sel now dangling; launch is ours)
					// needsFetch = 0-byte single-file stub OR a real multi-disc .m3u whose
					// discs are missing -> download-with-feedback first; else launch the file
					// that's fully on the card. (A real .m3u with missing discs black-screens
					// if handed straight to the emulator — route it through the fetch.)
					if (Lodor_needsFetch(launch->path)) {
						Lodor_downloadThenLaunch(screen, launch, 1); // stub / incomplete: download then launch
					} else {
						Entry_open(launch); // real file (all discs present) on card
					}
					Entry_free(launch);
					dirty = 1;
				}
				else if (PAD_justPressed(BTN_Y) && rc>0 && lodor_search_sel>=0 && lodor_search_sel<rc) {
					// Y opens the native per-game action menu for the selected result, exactly like
					// Y on the main menu. Lodor_openActions COPIES the entry path/name into statics
					// (lodor_rompath/lodor_gamename) -- it does not retain the pointer -- so passing the
					// borrowed results entry is safe and we keep lodor_search_results allocated underneath.
					Entry* rsel = lodor_search_results->items[lodor_search_sel];
					Lodor_openActions(rsel);
					lodor_actions_from_search = 1; // set AFTER openActions (its internal freeActions clears it)
					dirty = 1;
				}
				else if (PAD_justPressed(BTN_B)) {
					// back to the keyboard to refine the query (results freed lazily on next scan/close)
					lodor_search_phase = 0; dirty = 1;
				}
			}
		}
		else if (lodor_show_onboard) {
			// lodor: ONBOARDING WIZARD input. Owns the screen until config is complete.
			// Sub-mode 1: shared keyboard editing a target buffer (extracted to Lodor_kbInput
			// so the RetroAchievements overlay reuses the identical grid/nav/DONE/cancel).
			if (lodor_ob_kb_active) {
				Lodor_kbInput(&dirty);
			}
			// Sub-mode 2: step screens (welcome / server form / pair / device).
			else if (lodor_onboard_step==LODOR_OB_WELCOME) {
				// §2 [#38]: Wi-Fi setup is the FIRST functional step when the device is offline. If
				// already online (associated + real IP) skip straight to the Server step. Otherwise
				// route into native Wi-Fi setup (scan -> pick -> connect) BEFORE server/pair.
				if (PAD_justPressed(BTN_A)) {
					if (Lodor_obIsOnline()) {
						lodor_onboard_step = LODOR_OB_MODE; // §tailscale: chooser
					} else {
						lodor_ob_wifi_phase = 0;
						Lodor_obWifiScan(screen);        // blocking "Scanning..." then build the list
						lodor_onboard_step = LODOR_OB_WIFI;
					}
					dirty = 1;
				}
				// lodor escape-hatch: B backs OUT of onboarding into the normal MinUI library/
				// menu even when unconfigured, so a Wi-Fi-less first boot is not a trap. The user
				// can reach Wi-Fi setup (Tools), then re-enter via Sync -> "Re-connect RomM".
				// The library was already loaded by Menu_init() before the boot-gate, so we just
				// drop the overlay; no directory rebuild needed (unlike the completion path).
				else if (PAD_justPressed(BTN_B)) { lodor_show_onboard = 0; dirty = 1; }
			}
			else if (lodor_onboard_step==LODOR_OB_WIFI) {
				// §2 [#38]: native Wi-Fi setup. Phase 0 = SSID list; phase 1 = password keyboard.
				if (lodor_ob_wifi_phase==1) {
					// password entry reuses the shared OB keyboard (opened on entry below). When the
					// keyboard closes (DONE/START/B), we connect (if a key was entered) or re-prompt.
					if (lodor_ob_kb_active) {
						// handled by the shared keyboard input block above (it edits lodor_ob_wifi_psk).
					} else if (lodor_ob_kb_cancelled) {
						// password entry was cancelled (B) -> back to the network list, no connect.
						lodor_ob_wifi_psk[0] = '\0';
						lodor_ob_wifi_phase = 0; dirty = 1;
					} else {
						// keyboard confirmed (DONE/START) -> connect through the §1 honest path.
						int ok = Lodor_obWifiConnect(screen, lodor_ob_wifi_ssid, lodor_ob_wifi_psk);
						lodor_ob_wifi_psk[0] = '\0'; // wipe the typed password from memory after use
						if (ok) {
							Lodor_freeWifiList();
							lodor_onboard_step = LODOR_OB_MODE; // Wi-Fi connected -> Server step (--validate
							                                      // checks server reachability there, honestly)
						} else {
							// honest failure already shown by the overlay; back to the network list to
							// retry or pick another network. (Failure here = no usable Wi-Fi LINK, not an
							// unreachable server — server reachability is a separate, later step.)
							Lodor_inlineAck(screen, "Couldn't connect to that network.\nPick a network and try again.");
							lodor_ob_wifi_phase = 0;
						}
						dirty = 1;
					}
				} else {
					int wc = lodor_ob_wifi_list ? lodor_ob_wifi_list->count : 0;
					if (PAD_justRepeated(BTN_UP)) {
						// scroll-window navigation (mirrors the library/search list paging).
						if (wc>0) {
							lodor_ob_wifi_sel -= 1;
							if (lodor_ob_wifi_sel<0) {
								lodor_ob_wifi_sel = wc-1;
								int s = wc - (MAIN_ROW_COUNT-1);
								lodor_ob_wifi_start = (s<0)?0:s;
								lodor_ob_wifi_end = wc;
							} else if (lodor_ob_wifi_sel < lodor_ob_wifi_start) {
								lodor_ob_wifi_start -= 1; lodor_ob_wifi_end -= 1;
							}
							dirty = 1;
						}
					}
					else if (PAD_justRepeated(BTN_DOWN)) {
						if (wc>0) {
							lodor_ob_wifi_sel += 1;
							if (lodor_ob_wifi_sel>=wc) {
								lodor_ob_wifi_sel = 0;
								lodor_ob_wifi_start = 0;
								lodor_ob_wifi_end = (wc<(MAIN_ROW_COUNT-1))?wc:(MAIN_ROW_COUNT-1);
							} else if (lodor_ob_wifi_sel >= lodor_ob_wifi_end) {
								lodor_ob_wifi_start += 1; lodor_ob_wifi_end += 1;
							}
							dirty = 1;
						}
					}
					else if (PAD_justPressed(BTN_Y)) {
						// Y rescans (networks come and go).
						Lodor_obWifiScan(screen); dirty = 1;
					}
					else if (PAD_justPressed(BTN_A) && wc>0 && lodor_ob_wifi_sel>=0 && lodor_ob_wifi_sel<wc) {
						Entry* net = lodor_ob_wifi_list->items[lodor_ob_wifi_sel];
						strncpy(lodor_ob_wifi_ssid, net->path, sizeof(lodor_ob_wifi_ssid)-1);
						lodor_ob_wifi_ssid[sizeof(lodor_ob_wifi_ssid)-1]='\0';
						lodor_ob_wifi_psk[0] = '\0';
						// Security is auto-detected by the scan (carried in Entry->unique). OPEN ->
						// connect directly, skipping the keyboard entirely. SECURED (or unknown, which
						// the scan marks SECURED as an honest fallback) -> open the keyboard for the PSK.
						int is_open = (net->unique && strcmp(net->unique, "OPEN")==0);
						if (is_open) {
							lodor_ob_wifi_open = 1;
							int ok = Lodor_obWifiConnect(screen, lodor_ob_wifi_ssid, "");
							// Wi-Fi connected -> Server step (server reachability checked there).
							if (ok) { Lodor_freeWifiList(); lodor_onboard_step = LODOR_OB_MODE; }
							else Lodor_inlineAck(screen, "Couldn't connect to that network.\nPick a network and try again.");
						} else {
							lodor_ob_wifi_open = 0;
							lodor_ob_wifi_phase = 1;
							Lodor_obKbOpen(lodor_ob_wifi_psk, LODOR_OB_WIFI_PSK_MAX, "Password:", 0, 0);
						}
						dirty = 1;
					}
					else if (PAD_justPressed(BTN_B)) {
						// B from the network list backs to Welcome (escape hatch still available there).
						Lodor_freeWifiList();
						lodor_onboard_step = LODOR_OB_WELCOME; dirty = 1;
					}
				}
			}
				else if (lodor_onboard_step==LODOR_OB_MODE) {
					// §tailscale: "How will you reach RomM?" — LAN (default) / Tailscale / Advanced.
					const char* mlabels[3]; int mmodes[3];
					int mn = Lodor_obModeRows(mlabels, mmodes);
					if (lodor_ob_mode_sel >= mn) lodor_ob_mode_sel = mn-1;
					if (lodor_ob_mode_sel < 0) lodor_ob_mode_sel = 0;
					if (PAD_justRepeated(BTN_UP))   { lodor_ob_mode_sel = (lodor_ob_mode_sel-1+mn)%mn; dirty = 1; }
					else if (PAD_justRepeated(BTN_DOWN)) { lodor_ob_mode_sel = (lodor_ob_mode_sel+1)%mn; dirty = 1; }
					else if (PAD_justPressed(BTN_A)) {
						int chosen = mmodes[lodor_ob_mode_sel];
						lodor_ob_mode = chosen;
						if (chosen==LODOR_OB_MODE_LAN) {
							lodor_ob_https = 0; lodor_ob_insecure = 0; lodor_ob_field = LODOR_OB_F_HOST;
							lodor_onboard_step = LODOR_OB_LAN;
						} else if (chosen==LODOR_OB_MODE_TS) {
							// blocking QR sign-in; on success ask for the *.ts.net host next.
							if (Lodor_obTailscaleFlow(screen)) {
								lodor_ob_sc_sel = 0;
								Lodor_obKbOpen(lodor_ob_host, LODOR_OB_HOST_MAX, "RomM .ts.net address:", 1, 0);
								lodor_onboard_step = LODOR_OB_TS_HOST;
							}
						} else {
							lodor_ob_field = LODOR_OB_F_HOST;
							lodor_onboard_step = LODOR_OB_SERVER; // Advanced = the existing full server form
						}
						dirty = 1;
					}
					else if (PAD_justPressed(BTN_B)) { lodor_onboard_step = LODOR_OB_WELCOME; dirty = 1; }
				}
				else if (lodor_onboard_step==LODOR_OB_LAN) {
					// LAN: hostname (+ optional port), http, no proxy — a plain tier-0 host.
					if (PAD_justRepeated(BTN_UP) || PAD_justRepeated(BTN_DOWN)) {
						lodor_ob_field = (lodor_ob_field==LODOR_OB_F_HOST) ? LODOR_OB_F_PORT : LODOR_OB_F_HOST; dirty = 1;
					}
					else if (PAD_justPressed(BTN_A)) {
						if (lodor_ob_field==LODOR_OB_F_HOST) { lodor_ob_sc_sel=0; Lodor_obKbOpen(lodor_ob_host, LODOR_OB_HOST_MAX, "Hostname:", 1, 0); }
						else Lodor_obKbOpen(lodor_ob_port, LODOR_OB_PORT_MAX, "Port:", 0, 1);
						dirty = 1;
					}
					else if (PAD_justPressed(BTN_START)) {
						int host_blank = 1; for (const char* hp=lodor_ob_host; *hp; hp++){ if(*hp!=' ' && *hp!='\t'){ host_blank=0; break; } }
						if (host_blank) { Lodor_inlineAck(screen, "Enter your RomM address first."); dirty = 1; }
						else {
							lodor_ob_https = 0; // LAN is http
							char url[LODOR_OB_HOST_MAX+16]; Lodor_obBuildURL(url, sizeof(url));
							if (Lodor_obSubmitServer(screen, url, lodor_ob_port, 0)) lodor_onboard_step = LODOR_OB_PAIR;
							dirty = 1;
						}
					}
					else if (PAD_justPressed(BTN_B)) { lodor_onboard_step = LODOR_OB_MODE; dirty = 1; }
				}
				else if (lodor_onboard_step==LODOR_OB_TS_HOST) {
					// Tailscale connected: enter the RomM *.ts.net host -> tier-1 host (socks5_proxy + tier).
					if (!lodor_ob_kb_active) {
						if (PAD_justPressed(BTN_A)) { lodor_ob_sc_sel=0; Lodor_obKbOpen(lodor_ob_host, LODOR_OB_HOST_MAX, "RomM .ts.net address:", 1, 0); dirty=1; }
						else if (PAD_justPressed(BTN_START)) {
							int host_blank = 1; for (const char* hp=lodor_ob_host; *hp; hp++){ if(*hp!=' ' && *hp!='\t'){ host_blank=0; break; } }
							if (host_blank) { Lodor_inlineAck(screen, "Enter your RomM's Tailscale address -\nits MagicDNS name, ending in .ts.net\n(e.g. romm.yournet.ts.net)."); dirty=1; }
							else {
								// A bare 100.x/tailnet IP can NEVER reach a `tailscale serve` RomM:
								// serve routes by hostname/SNI, so an IP carries no name and is dropped
								// (the engine resolves the .ts.net name via the SOCKS5 proxy). Refuse it
								// here with a clear reason instead of letting --validate fail opaquely.
								int ip_like = (lodor_ob_host[0] != '\0');
								for (const char* hp=lodor_ob_host; *hp; hp++){ if(!((*hp>='0'&&*hp<='9')||*hp=='.')){ ip_like=0; break; } }
								if (ip_like) { Lodor_inlineAck(screen, "A 100.x IP can't reach a Tailscale-served\nRomM. Use its MagicDNS name, ending\nin .ts.net (e.g. romm.yournet.ts.net)."); dirty=1; }
								else {
								lodor_ob_https = 1; // tailnet is https
								char url[LODOR_OB_HOST_MAX+16]; Lodor_obBuildURL(url, sizeof(url));
								// TS ORDER (critical): persist server -> mark host tier-1 (writes socks5_proxy
								// so the engine dials via tailscaled SOCKS5 + remote MagicDNS) -> THEN validate.
								// Validating BEFORE mark-tier1 deadlocked: a .ts.net name has no route without
								// the SOCKS5 proxy, so --validate always failed and mark-tier1 (gated on its
								// success) never ran, so socks5_proxy never got written. Reordered to fix that.
								char qurl[LODOR_OB_HOST_MAX+32]; Lodor_shq(url, qurl, sizeof(qurl));
								char cmd[MAX_PATH*3], out[1024];
								int server_set = 0;
								snprintf(cmd, sizeof(cmd), "'%s%s' --set-server '%s'", SDCARD_PATH, LODOR_ROMM_BIN, qurl);
								Lodor_runWithProgress(screen, "Saving server...", cmd, out, sizeof(out));
								{ char* ln=out; while(ln&&*ln){ int v; if(sscanf(ln,"RESULT server_set=%d",&v)==1) server_set=v; char* nx=strchr(ln,'\n'); ln=nx?nx+1:NULL; } }
								if (!server_set) {
									Lodor_inlineAck(screen, "Couldn't save the server.\nCheck the address and retry.");
								} else {
									// mark hosts[0] tier-1 so the engine's SOCKS5 dialer routes through localhost:1055.
									char qh[LODOR_OB_HOST_MAX+8]; Lodor_shq(lodor_ob_host, qh, sizeof(qh));
									char tcmd[MAX_PATH*2], tout[256];
									snprintf(tcmd, sizeof(tcmd), "'%s%s' mark-tier1 '%s'", SDCARD_PATH, LODOR_TS_BIN, qh);
									Lodor_runWithProgress(screen, "Saving Tailscale route...", tcmd, tout, sizeof(tout));
									// validate THROUGH the SOCKS5 route now that socks5_proxy is set.
									int reachable=0, auth=0; (void)auth;
									snprintf(cmd, sizeof(cmd), "'%s%s' --validate", SDCARD_PATH, LODOR_ROMM_BIN);
									Lodor_runWithProgress(screen, "Reaching RomM over Tailscale...", cmd, out, sizeof(out));
									{ char* ln=out; while(ln&&*ln){ int r,a; if(sscanf(ln,"RESULT reachable=%d auth=%d",&r,&a)==2){reachable=r;auth=a;} char* nx=strchr(ln,'\n'); ln=nx?nx+1:NULL; } }
									if (!reachable) {
										Lodor_inlineAck(screen, "Couldn't reach RomM over Tailscale.\nIs Tailscale connected and the\n.ts.net name correct?");
									} else {
										lodor_onboard_step = LODOR_OB_PAIR;
									}
								}
								dirty = 1;
								}
							}
						}
						else if (PAD_justPressed(BTN_B)) { lodor_onboard_step = LODOR_OB_MODE; dirty = 1; }
					}
				}
			else if (lodor_onboard_step==LODOR_OB_SERVER) {
				int ssl_visible = lodor_ob_https;
				int maxfield = ssl_visible ? LODOR_OB_F_COUNT : LODOR_OB_F_COUNT-1;
				if (PAD_justRepeated(BTN_UP))   { lodor_ob_field = (lodor_ob_field-1+maxfield)%maxfield; dirty = 1; }
				else if (PAD_justRepeated(BTN_DOWN)) { lodor_ob_field = (lodor_ob_field+1)%maxfield; dirty = 1; }
				else if (PAD_justRepeated(BTN_LEFT) || PAD_justRepeated(BTN_RIGHT)) {
					if (lodor_ob_field==LODOR_OB_F_PROTO) { lodor_ob_https = !lodor_ob_https; if (!lodor_ob_https) lodor_ob_insecure = 0; }
					else if (lodor_ob_field==LODOR_OB_F_SSL) lodor_ob_insecure = !lodor_ob_insecure;
					dirty = 1;
				}
				else if (PAD_justPressed(BTN_A)) {
					if (lodor_ob_field==LODOR_OB_F_HOST) { lodor_ob_sc_sel=0; Lodor_obKbOpen(lodor_ob_host, LODOR_OB_HOST_MAX, "Hostname:", 1, 0); }
					else if (lodor_ob_field==LODOR_OB_F_PORT) Lodor_obKbOpen(lodor_ob_port, LODOR_OB_PORT_MAX, "Port:", 0, 1);
					else if (lodor_ob_field==LODOR_OB_F_PROTO) { lodor_ob_https = !lodor_ob_https; if (!lodor_ob_https) lodor_ob_insecure = 0; }
					else if (lodor_ob_field==LODOR_OB_F_SSL) lodor_ob_insecure = !lodor_ob_insecure;
					dirty = 1;
				}
				else if (PAD_justPressed(BTN_START)) {
					// robustness: a hostname of only whitespace is empty for our purposes.
					int host_blank = 1;
					for (const char* hp=lodor_ob_host; *hp; hp++) { if (*hp!=' ' && *hp!='\t') { host_blank=0; break; } }
					if (host_blank) {
						Lodor_inlineAck(screen, "Enter a hostname first.");
						dirty = 1;
					} else {
						// 1) persist server (engine creates config.json if absent) 2) validate.
						char url[LODOR_OB_HOST_MAX+16]; Lodor_obBuildURL(url, sizeof(url));
						char qurl[LODOR_OB_HOST_MAX+32]; Lodor_shq(url, qurl, sizeof(qurl));
						char cmd[MAX_PATH*3], out[1024];
						// --set-server
						if (lodor_ob_port[0]) {
							char qport[16]; Lodor_shq(lodor_ob_port, qport, sizeof(qport));
							snprintf(cmd, sizeof(cmd), "'%s%s' --set-server '%s' --port '%s'%s",
								SDCARD_PATH, LODOR_ROMM_BIN, qurl, qport, lodor_ob_insecure?" --insecure":"");
						} else {
							snprintf(cmd, sizeof(cmd), "'%s%s' --set-server '%s'%s",
								SDCARD_PATH, LODOR_ROMM_BIN, qurl, lodor_ob_insecure?" --insecure":"");
						}
						int server_set = 0;
						Lodor_runWithProgress(screen, "Saving server...", cmd, out, sizeof(out));
						{ char* ln=out; while(ln&&*ln){ int v; if(sscanf(ln,"RESULT server_set=%d",&v)==1) server_set=v; char* nx=strchr(ln,'\n'); ln=nx?nx+1:NULL; } }
						if (!server_set) {
							// set-server runs 2>&1 into `out`: a malformed URL tags "invalid url"
							// (exit 2); anything else is a write/parse failure. Distinct messages.
							if (strstr(out, "invalid url"))
								Lodor_inlineAck(screen, "That address doesn't look right.\nCheck the hostname and try again.");
							else
								Lodor_inlineAck(screen, "Couldn't save the server.\nCheck the address and retry.");
							dirty = 1; // form re-renders with the user's entries intact (preserved edits)
						} else {
							// --validate (reachability + auth; auth will be 0 pre-pair, that's fine)
							int reachable=0, auth=0; (void)auth;
							snprintf(cmd, sizeof(cmd), "'%s%s' --validate", SDCARD_PATH, LODOR_ROMM_BIN);
							Lodor_runWithProgress(screen, "Reaching RomM...", cmd, out, sizeof(out));
							{ char* ln=out; while(ln&&*ln){ int r,a; if(sscanf(ln,"RESULT reachable=%d auth=%d",&r,&a)==2){reachable=r;auth=a;} char* nx=strchr(ln,'\n'); ln=nx?nx+1:NULL; } }
							if (!reachable) {
								Lodor_inlineAck(screen, "Couldn't reach RomM at that address.\nFor Tailscale use the .ts.net name (not\nthe 100.x IP); for home use the LAN IP.");
								dirty = 1; // PRESERVED EDITS: form keeps host/port/proto/ssl
							} else {
								lodor_onboard_step = LODOR_OB_PAIR; dirty = 1;
							}
						}
					}
				}
				else if (PAD_justPressed(BTN_B)) {
					lodor_onboard_step = LODOR_OB_MODE; dirty = 1; // Advanced backs to the chooser
				}
			}
			else if (lodor_onboard_step==LODOR_OB_PAIR) {
				// The pairing-code keyboard is opened on-demand; if it's closed and the
				// buffer has a code, START submits. A press of A (when keyboard closed)
				// re-opens it to edit. We open it automatically on entry below (render).
				if (!lodor_ob_kb_active) {
					if (PAD_justPressed(BTN_A)) { Lodor_obKbOpen(lodor_ob_code, LODOR_OB_CODE_MAX, "Pair code:", 0, 0); dirty=1; }
					else if (PAD_justPressed(BTN_START)) {
						if (lodor_ob_code[0]=='\0') { Lodor_inlineAck(screen, "Enter the 8-digit pair code\nfrom RomM's web UI."); dirty=1; }
						else if (lodor_ob_add_profile) {
							char qcodeP[32]; Lodor_shq(lodor_ob_code, qcodeP, sizeof(qcodeP));
							char cmdP[MAX_PATH*2], outP[1024];
							snprintf(cmdP, sizeof(cmdP), "'%s%s' --pair-profile '%s'", SDCARD_PATH, LODOR_ROMM_BIN, qcodeP);
							char puser[64]="";
							Lodor_runWithProgress(screen, "Signing in...", cmdP, outP, sizeof(outP));
							int pairedP = (strstr(outP, "paired=1") != NULL);
							char* upP = strstr(outP, "username=");
							if (upP) sscanf(upP, "username=%63s", puser);
							lodor_ob_code[0] = 0;
							if (!pairedP || !puser[0]) {
								Lodor_inlineAck(screen, "Invalid or expired code. Mint a new one in RomM and try again.");
								dirty = 1;
							} else {
								Lodor_writeActiveProfile(screen, puser);
								snprintf(lodor_profile_label, sizeof(lodor_profile_label), "%s", puser);
								lodor_user_badge = Lodor_readUserBadge();
								lodor_ob_add_profile = 0; lodor_show_onboard = 0; lodor_show_profiles = 0;
								char mP[128]; snprintf(mP, sizeof(mP), "Signed in as %s", puser);
								Lodor_drawMessage(screen, mP); SDL_Delay(1200);
								dirty = 1;
							}
						}
						else {
							char qcode[32]; Lodor_shq(lodor_ob_code, qcode, sizeof(qcode));
							char cmd[MAX_PATH*2], out[1024];
							snprintf(cmd, sizeof(cmd), "'%s%s' --pair '%s'", SDCARD_PATH, LODOR_ROMM_BIN, qcode);
							int paired=0, scopes_ok=0;
							Lodor_runWithProgress(screen, "Pairing...", cmd, out, sizeof(out));
							{ char* ln=out; while(ln&&*ln){ int p,s; if(sscanf(ln,"RESULT paired=%d scopes_ok=%d",&p,&s)==2){paired=p;scopes_ok=s;} char* nx=strchr(ln,'\n'); ln=nx?nx+1:NULL; } }
							if (!paired) {
								lodor_ob_code[0]='\0'; // wipe the bad/expired code
								Lodor_inlineAck(screen, "Invalid or expired code.\nMint a new one in RomM and\ntry again.");
								dirty = 1;
							} else {
								lodor_ob_code[0]='\0'; // SECURITY: clear the code from memory once exchanged
								if (!scopes_ok) Lodor_inlineAck(screen, "Paired, but the token is\nmissing some sync scopes.\nSaves may not sync until you\nre-mint with full scopes.");
								lodor_onboard_step = LODOR_OB_DEVICE; dirty = 1;
							}
						}
					}
						else if (PAD_justPressed(BTN_B)) {
							if (lodor_ob_add_profile) { lodor_ob_code[0]=0; lodor_ob_add_profile = 0; lodor_show_onboard = 0; Lodor_readActiveProfile(lodor_profile_label, sizeof(lodor_profile_label)); Lodor_buildProfiles(); lodor_show_profiles = 1; lodor_profiles_sel = 0; dirty = 1; }
							else { if (lodor_ob_mode==LODOR_OB_MODE_LAN) lodor_onboard_step = LODOR_OB_LAN; else if (lodor_ob_mode==LODOR_OB_MODE_TS) lodor_onboard_step = LODOR_OB_TS_HOST; else lodor_onboard_step = LODOR_OB_SERVER; dirty = 1; }
						}
				}
			}
			else if (lodor_onboard_step==LODOR_OB_DEVICE) {
				if (!lodor_ob_kb_active) {
					if (PAD_justPressed(BTN_A)) { Lodor_obKbOpen(lodor_ob_name, LODOR_OB_NAME_MAX, "Device name:", 0, 0); dirty=1; }
					else if (PAD_justPressed(BTN_START)) {
						if (lodor_ob_name[0]=='\0') { Lodor_inlineAck(screen, "Give this device a name."); dirty=1; }
						else {
							char qname[128]; Lodor_shq(lodor_ob_name, qname, sizeof(qname));
							char cmd[MAX_PATH*2], out[1024];
							snprintf(cmd, sizeof(cmd), "'%s%s' --register-device '%s'", SDCARD_PATH, LODOR_ROMM_BIN, qname);
							int registered=0;
							Lodor_runWithProgress(screen, "Registering device...", cmd, out, sizeof(out));
							{ char* ln=out; while(ln&&*ln){ int r; if(sscanf(ln,"RESULT registered=%d",&r)==1) registered=r; char* nx=strchr(ln,'\n'); ln=nx?nx+1:NULL; } }
							if (!registered) {
								Lodor_inlineAck(screen, "Couldn't register the device.\nCheck WiFi and try again.");
								dirty = 1;
							} else {
								// First mirror behind the Working overlay, then drop into the library.
								snprintf(cmd, sizeof(cmd), "'%s%s' --mirror-catalog", SDCARD_PATH, LODOR_ROMM_BIN);
								Lodor_runWithProgress(screen, "Building your library...", cmd, out, sizeof(out));
								snprintf(cmd, sizeof(cmd), "'%s%s' --mirror-collections", SDCARD_PATH, LODOR_ROMM_BIN);
								Lodor_runWithProgress(screen, "Loading collections...", cmd, out, sizeof(out));
								lodor_show_onboard = 0;
								lodor_onboard_step = LODOR_OB_DONE;
								// Rebuild the root in place so the freshly-mirrored Roms/Collections
								// stubs appear. At onboarding completion the stack is exactly the root
								// (we never navigated), so pop+free that single Directory and re-open
								// SDCARD_PATH rather than calling closeDirectory() (which underflows at
								// depth 1 by dereferencing stack[count-1] after the pop).
								while (stack->count > 1) DirectoryArray_pop(stack);
								DirectoryArray_pop(stack); // free the lone root Directory
								restore_depth = -1; restore_relative = -1; restore_selected = 0;
								restore_start = 0; restore_end = 0;
								top = NULL;
								openDirectory(SDCARD_PATH, 0);
								Lodor_inlineAck(screen, "You're connected!\nYour library is ready.");
								dirty = 1;
							}
						}
					}
					else if (PAD_justPressed(BTN_B)) {
						if (lodor_ob_add_profile) {
							unsetenv("LODOR_PROFILE");
							lodor_ob_add_profile = 0;
							lodor_show_onboard = 0;
							Lodor_readActiveProfile(lodor_profile_label, sizeof(lodor_profile_label));
							Lodor_buildProfiles();
							lodor_show_profiles = 1; lodor_profiles_sel = 0;
							dirty = 1;
						} else { lodor_onboard_step = LODOR_OB_PAIR; dirty = 1; }
					}
				}
			}
			else if (lodor_onboard_step==LODOR_OB_LOGIN_USER) {
				// FEATURE 2: existing-RomM-user username keyboard (Add-Profile sign-in).
				if (lodor_ob_kb_active) {
					Lodor_kbInput(&dirty);
				}
				else if (lodor_ob_kb_cancelled || !lodor_ob_login_user[0]) {
					// cancelled / empty -> back out to the profile switcher (no account made)
					lodor_ob_login_user[0]='\0';
					lodor_ob_add_profile = 0; lodor_show_onboard = 0;
					Lodor_readActiveProfile(lodor_profile_label, sizeof(lodor_profile_label));
					Lodor_buildProfiles();
					lodor_show_profiles = 1; lodor_profiles_sel = 0; dirty = 1;
				}
				else {
					// username captured -> masked password keyboard
					lodor_ob_login_pass[0]='\0';
					Lodor_obKbOpen(lodor_ob_login_pass, sizeof(lodor_ob_login_pass), "RomM password:", 0, 0);
					lodor_ob_kb_mask = 1;
					lodor_onboard_step = LODOR_OB_LOGIN_PASS; dirty = 1;
				}
			}
			else if (lodor_onboard_step==LODOR_OB_LOGIN_PASS) {
				// FEATURE 2: password keyboard just closed -> SIGN IN as the existing user.
				if (lodor_ob_kb_active) {
					Lodor_kbInput(&dirty);
				}
				else if (lodor_ob_kb_cancelled || !lodor_ob_login_pass[0]) {
					// cancelled / empty password -> back to the user picker (never type a name)
					lodor_ob_login_pass[0]='\0'; lodor_ob_login_user[0]='\0';
					lodor_ob_add_profile = 0; lodor_show_onboard = 0;
					Lodor_readActiveProfile(lodor_profile_label, sizeof(lodor_profile_label));
					Lodor_buildProfiles();
					lodor_show_profiles = 1; lodor_profiles_sel = 0; dirty = 1;
				}
				else {
					// Shell the engine login. SECURITY: the password goes via STDIN (never argv)
					// AND is passed to the shell only through an env var, so it appears in neither
					// the literal command nor romm-run/engine argv. The profile label is the
					// (already-typed) device name; the engine creates+activates the profile, signs
					// in via the OAuth2 password grant, and registers this device — NO account is
					// ever created. Engine prints "RESULT logged_in=<0|1> registered=<0|1> scopes_ok=<0|1>".
					char qlabel[128]; Lodor_shq(lodor_ob_name, qlabel, sizeof(qlabel));
					setenv("LODOR_LOGIN_U", lodor_ob_login_user, 1);
					setenv("LODOR_LOGIN_P", lodor_ob_login_pass, 1);
					char cmd[MAX_PATH*3], lout[1024];
					snprintf(cmd, sizeof(cmd),
						"printf '%%s\\n' \"$LODOR_LOGIN_P\" | '%s%s' --login-profile '%s' --login-user \"$LODOR_LOGIN_U\" --login-device '%s'",
						SDCARD_PATH, LODOR_ROMM_BIN, qlabel, qlabel);
					Lodor_runWithProgress(screen, "Signing in to RomM...", cmd, lout, sizeof(lout));
					unsetenv("LODOR_LOGIN_P"); unsetenv("LODOR_LOGIN_U");
					int logged_in=-1;
					{ char* ln=lout; while(ln&&*ln){ int li;
						if(sscanf(ln,"RESULT logged_in=%d",&li)==1){logged_in=li;}
						char* nx=strchr(ln,'\n'); ln=nx?nx+1:NULL; } }
					char uname[LODOR_OB_LOGINUSER_MAX]; snprintf(uname, sizeof(uname), "%s", lodor_ob_login_user);
					lodor_ob_login_pass[0]='\0'; // wipe the typed password immediately after use
					if (logged_in==1) {
						// Signed in: the new profile host now holds this user's token. Activate them
						// (write active-profile.txt + rebuild library) and load their collections,
						// then close the overlay back to the library with the new user live.
						Lodor_writeActiveProfile(screen, uname);
						char mcmd[MAX_PATH*2], mout[512];
						snprintf(mcmd, sizeof(mcmd), "'%s%s' --mirror-collections", SDCARD_PATH, LODOR_ROMM_BIN);
						Lodor_runWithProgress(screen, "Loading collections...", mcmd, mout, sizeof(mout));
						snprintf(lodor_profile_label, sizeof(lodor_profile_label), "%s", uname);
						lodor_user_badge = Lodor_readUserBadge();
						lodor_ob_login_user[0]='\0';
						lodor_ob_add_profile = 0; lodor_show_onboard = 0; lodor_show_profiles = 0;
						Lodor_inlineAck(screen, "Signed in to RomM.");
						dirty = 1;
					} else if (logged_in==0) {
						// bad credentials -> show the error and stay in the picker (no account made)
						Lodor_drawMessage(screen, "RomM sign-in failed --\ncheck the password and try again"); SDL_Delay(2200);
						lodor_ob_login_user[0]='\0';
						lodor_ob_add_profile = 0; lodor_show_onboard = 0;
						Lodor_readActiveProfile(lodor_profile_label, sizeof(lodor_profile_label));
						Lodor_buildProfiles();
						lodor_show_profiles = 1; lodor_profiles_sel = 0; dirty = 1;
					} else {
						// no RESULT line => engine never ran (Wi-Fi down / server unreachable). Honest.
						Lodor_drawMessage(screen, "Couldn't reach RomM"); SDL_Delay(2000);
						lodor_ob_login_user[0]='\0';
						lodor_ob_add_profile = 0; lodor_show_onboard = 0;
						Lodor_readActiveProfile(lodor_profile_label, sizeof(lodor_profile_label));
						Lodor_buildProfiles();
						lodor_show_profiles = 1; lodor_profiles_sel = 0; dirty = 1;
					}
				}
			}
		}
		else if (show_version) {
			if (PAD_justPressed(BTN_B) || PAD_tappedMenu(now)) {
				show_version = 0;
				dirty = 1;
				if (!HAS_POWER_BUTTON && !simple_mode) PWR_disableSleep();
			}
		}
		else {
			// lodor: pending-saves BADGE — clickable indicator inline above the watermark. At root,
			// RIGHT focuses it; A uploads pending saves; B/LEFT/UP/DOWN return to the list.
			// lodor: a fresh "synced ✓" flash clears on the NEXT user input. Ack it (persist the ts
			// so it won't re-show) on any button activity, WITHOUT consuming the press — the same
			// frame still does its normal job below. dirty=1 forces the repaint that drops the badge.
			if (lodor_synced_shown_ts > 0 && (
					PAD_justPressed(BTN_A)||PAD_justPressed(BTN_B)||PAD_justPressed(BTN_Y)||
					PAD_justRepeated(BTN_UP)||PAD_justRepeated(BTN_DOWN)||
					PAD_justRepeated(BTN_LEFT)||PAD_justRepeated(BTN_RIGHT)||
					PAD_justPressed(BTN_L1)||PAD_justPressed(BTN_R1)||
					PAD_justPressed(BTN_SELECT)||PAD_tappedMenu(now))) {
				Lodor_ackSynced(lodor_synced_shown_ts);
				lodor_synced_shown_ts = 0;
				dirty = 1;
			}
			int lodor_np = (stack && stack->count==1) ? Lodor_pendingCount() : 0;
			// lodor §toast: when the pending-saves backlog GROWS at root (a save was just
			// queued locally — e.g. returned from a game and the push couldn't land), surface an
			// honest transient toast. The wording reflects real connectivity (PLAT_isOnline): an
			// offline device says so. Grounded in pending-saves.txt actually growing — never faked.
			if (stack && stack->count==1) {
				if (lodor_prev_pending >= 0 && lodor_np > lodor_prev_pending) {
					int added = lodor_np - lodor_prev_pending;
					int online = PLAT_isOnline();
					char tm[96];
					if (online) snprintf(tm, sizeof(tm), added==1 ? "Save queued to sync" : "%d saves queued to sync", added);
					else        snprintf(tm, sizeof(tm), added==1 ? "Save queued — offline" : "%d saves queued — offline", added);
					Lodor_toastPush(tm, online ? LODOR_TOAST_INFO : LODOR_TOAST_OFFLINE);
				}
				lodor_prev_pending = lodor_np;
			}
			if (lodor_badge_focused && lodor_np<=0) lodor_badge_focused = 0;
			if (lodor_badge_focused) {
				if (PAD_justPressed(BTN_A)) {
					char pcmd[MAX_PATH*3], pout[2048]; int pushed=-1, stuck=0; char stuckwhy[256]="";
					snprintf(pcmd, sizeof(pcmd), "'%s%s' --push-pending", SDCARD_PATH, LODOR_ROMM_BIN);
					Lodor_runWithProgress(screen, "Uploading saves...", pcmd, pout, sizeof(pout));
					{ char* ln=pout; while(ln&&*ln){ int n,m,k; char g[160],w[160];
						if(sscanf(ln,"RESULT pushed=%d total=%d stuck=%d",&n,&m,&k)==3){pushed=n;stuck=k;}
						else if(!stuckwhy[0]&&sscanf(ln,"STUCK\t%159[^\t]\t%159[^\r\n]",g,w)==2) snprintf(stuckwhy,sizeof(stuckwhy),"%s:\n%s",g,w);
						char* nx=strchr(ln,'\n'); ln=nx?nx+1:NULL; } }
					if(stuck>0){ char sm[320]; snprintf(sm,sizeof(sm),"%d save%s couldn't upload --\n%s",stuck,stuck==1?"":"s",stuckwhy[0]?stuckwhy:"see logs"); Lodor_drawMessage(screen,sm); SDL_Delay(2800); }
					else if(pushed>=0){ char m2[64]; snprintf(m2,sizeof(m2),"Uploaded %d save%s",pushed,pushed==1?"":"s"); Lodor_drawMessage(screen,m2); SDL_Delay(1400); }
					if (Lodor_pendingCount()<=0) lodor_badge_focused = 0;
					lodor_keepawake_until = SDL_GetTicks()+15000;
					dirty = 1;
				}
				else if (PAD_justPressed(BTN_B) || PAD_justPressed(BTN_LEFT) || PAD_justRepeated(BTN_UP) || PAD_justRepeated(BTN_DOWN)) {
					lodor_badge_focused = 0; dirty = 1;
				}
			}
			else if (PAD_tappedMenu(now)) {
				show_version = 1;
				dirty = 1;
				if (!HAS_POWER_BUTTON && !simple_mode) PWR_enableSleep();
			}
			else if (total>0) {
				if (PAD_justRepeated(BTN_UP)) {
					if (selected==0 && !PAD_justPressed(BTN_UP)) {
						// stop at top
					}
					else {
						selected -= 1;
						if (selected<0) {
							selected = total-1;
							int start = total - MAIN_ROW_COUNT;
							top->start = (start<0) ? 0 : start;
							top->end = total; 
						}
						else if (selected<top->start) {
							top->start -= 1;
							top->end -= 1;
						}
					}
				}
				else if (PAD_justRepeated(BTN_DOWN)) {
					if (selected==total-1 && !PAD_justPressed(BTN_DOWN)) {
						// stop at bottom
					}
					else {
						selected += 1;
						if (selected>=total) {
							selected = 0;
							top->start = 0;
							top->end = (total<MAIN_ROW_COUNT) ? total : MAIN_ROW_COUNT;
						}
						else if (selected>=top->end) {
							top->start += 1;
							top->end += 1;
						}
					}
				}
				if (PAD_justRepeated(BTN_LEFT)) {
					selected -= MAIN_ROW_COUNT;
					if (selected<0) {
						selected = 0;
						top->start = 0;
						top->end = (total<MAIN_ROW_COUNT) ? total : MAIN_ROW_COUNT;
					}
					else if (selected<top->start) {
						top->start -= MAIN_ROW_COUNT;
						if (top->start<0) top->start = 0;
						top->end = top->start + MAIN_ROW_COUNT;
					}
				}
				else if (PAD_justRepeated(BTN_RIGHT) && lodor_np>0 && !lodor_badge_focused) {
					lodor_badge_focused = 1; dirty = 1; // RIGHT -> focus the pending-saves badge
				}
				else if (PAD_justRepeated(BTN_RIGHT)) {
					selected += MAIN_ROW_COUNT;
					if (selected>=total) {
						selected = total-1;
						int start = total - MAIN_ROW_COUNT;
						top->start = (start<0) ? 0 : start;
						top->end = total;
					}
					else if (selected>=top->end) {
						top->end += MAIN_ROW_COUNT;
						if (top->end>total) top->end = total;
						top->start = top->end - MAIN_ROW_COUNT;
					}
				}
			}
		
			if (!lodor_badge_focused && PAD_justRepeated(BTN_L1) && !PAD_isPressed(BTN_R1) && !PWR_ignoreSettingInput(BTN_L1, show_setting)) { // previous alpha
				Entry* entry = top->entries->items[selected];
				int i = entry->alpha-1;
				if (i>=0) {
					selected = top->alphas->items[i];
					if (total>MAIN_ROW_COUNT) {
						top->start = selected;
						top->end = top->start + MAIN_ROW_COUNT;
						if (top->end>total) top->end = total;
						top->start = top->end - MAIN_ROW_COUNT;
					}
				}
			}
			else if (!lodor_badge_focused && PAD_justRepeated(BTN_R1) && !PAD_isPressed(BTN_L1) && !PWR_ignoreSettingInput(BTN_R1, show_setting)) { // next alpha
				Entry* entry = top->entries->items[selected];
				int i = entry->alpha+1;
				if (i<top->alphas->count) {
					selected = top->alphas->items[i];
					if (total>MAIN_ROW_COUNT) {
						top->start = selected;
						top->end = top->start + MAIN_ROW_COUNT;
						if (top->end>total) top->end = total;
						top->start = top->end - MAIN_ROW_COUNT;
					}
				}
			}
	
			if (selected!=top->selected) {
				top->selected = selected;
				dirty = 1;
			}
	
			if (dirty && total>0) readyResume(top->entries->items[top->selected]);

			if (!lodor_badge_focused && total>0 && can_resume && PAD_justReleased(BTN_RESUME)) {
				should_resume = 1;
				Entry_open(top->entries->items[top->selected]);
				dirty = 1;
			}
			else if (!lodor_badge_focused && PAD_justReleased(BTN_RESUME)) {
				// lodor §gameswitch (#149): X opens the Game Switcher. NOTE: X was NOT free —
				// BTN_RESUME==BTN_X on all four families — so the highlighted entry's
				// quick-resume keeps priority (branch above); the switcher takes X everywhere
				// else (root, folders, games without a resume state).
				Lodor_openSwitcher();
				if (lodor_switch_count>0) { lodor_show_switch = 1; dirty = 1; }
			}
			else if (total>0 && PAD_justPressed(BTN_A)) {
				Entry* lodor_a = top->entries->items[top->selected];
				// lodor: intercept the two injected special PAK rows + 0-byte cloud-stub ROMs and
				// open native overlays instead of launching grout32. Everything else: normal open.
				int lodor_handled = 0;
				if (lodor_a->type==ENTRY_PAK && lodor_a->name &&
				    (strncmp(lodor_a->name,"There are ",10)==0 || strncmp(lodor_a->name,"There is ",9)==0)) {
					// Task 4: the "Saves Pending" banner -> push pending saves natively.
					char pcmd[MAX_PATH*3];
					char pout[1024];
					snprintf(pcmd, sizeof(pcmd), "'%s%s' --push-pending",
						SDCARD_PATH, LODOR_ROMM_BIN);
					Lodor_runWithProgress(screen, "Uploading saves...", pcmd, pout, sizeof(pout));
					int pn=-1, pm=0, pk=0;
					{ char* ln = pout; while (ln && *ln) {
						int n,m,k; if (sscanf(ln, "RESULT pushed=%d total=%d stuck=%d", &n,&m,&k)==3) { pn=n; pm=m; pk=k; }
						char* nx = strchr(ln, '\n'); ln = nx ? nx+1 : NULL; } }
					if (pk>0) {
						lodor_confirm_kind = 3; // dismiss the pending reminder
						lodor_confirm_stuck = pk;
						lodor_show_confirm = 1;
					} else {
						char rm[64]; int shown = pn>=0 ? pn : pm;
						snprintf(rm, sizeof(rm), "Uploaded %d save%s", shown, shown==1?"":"s");
						Lodor_drawMessage(screen, rm); SDL_Delay(1200);
					}
					// lodor: the banner row is built by getRoot() at menu load and counts
					// pending-saves.txt; dirty=1 only re-renders the cached list. Rebuild the
					// root so the banner reflects the new count (disappears at 0).
					Lodor_refreshBanner();
					dirty = 1;
					lodor_handled = 1;
				}
				else if (lodor_a->type==ENTRY_PAK && lodor_a->path && (suffixMatch("/Lodor.pak", lodor_a->path) || suffixMatch("/Sync.pak", lodor_a->path))) {
					// lodor TWO-MENU model: the SAME pak path backs two root-stack entries.
					//  - injected at ROOT (top->path == SDCARD_PATH) -> routine SYNC front-door.
					//  - listed under TOOLS (any deeper directory)    -> Lodor/RomM SETTINGS.
					// Discriminate purely by location so the front-door byte-path stays identical.
					int grace; Lodor_readWifiWarm(&lodor_wifi_warm, &grace);
					lodor_quality_dots = Lodor_readQualityDots();
					lodor_user_badge = Lodor_readUserBadge();
					lodor_box_art = Lodor_readBoxArt();
					Lodor_readActiveProfile(lodor_profile_label, sizeof(lodor_profile_label));
					if (exactMatch(top->path, SDCARD_PATH)) {
						Lodor_computeStorage(); // FEATURE 1: storage header, computed once on open
						lodor_show_sync = 1; lodor_sync_sel = 0; dirty = 1;
					} else {
						Lodor_readRAUser(lodor_ra_status, sizeof(lodor_ra_status)); // for the RA settings row label
						lodor_show_settings = 1; lodor_settings_sel = 0; dirty = 1;
					}
					lodor_handled = 1;
				}
				else if (lodor_a->type==ENTRY_ROM) {
					// Task 5 + multi-disc fix: a 0-byte cloud stub OR a real multi-disc .m3u
					// whose referenced discs are missing/stub -> download with feedback BEFORE
					// launching (never hand the emulator an .m3u with absent discs: black screen).
					if (Lodor_needsFetch(lodor_a->path)) {
						if (Lodor_downloadThenLaunch(screen, lodor_a, 1)) {
							// launched via Entry_open; fall through to bookkeeping below
						} else {
							lodor_handled = 1; // download failed; stay on the menu
						}
					} else {
						Entry_open(lodor_a);
					}
				}
				else {
					Entry_open(lodor_a);
				}
				if (!lodor_handled) {
					total = top->entries->count;
					if (total>0) readyResume(top->entries->items[top->selected]);
				}
				dirty = 1;
			}
			else if (!lodor_badge_focused && total>0 && PAD_justPressed(BTN_Y)) {
				// lodor: Y opens the NATIVE per-game action menu (Play / Sync save / Server saves /
				// Delete / Details for on-card ROMs; Play / Download now / Add to queue / Details for
				// 0-byte cloud stubs) instead of launching the game. Position-saving for B-back is
				// handled by the Play action (it routes through Entry_open like a normal A-press).
				Entry* lodor_sel = top->entries->items[top->selected];
				if (lodor_sel->type==ENTRY_ROM) {
					Lodor_openActions(lodor_sel);
					dirty = 1;
				}
			}
			else if (PAD_justPressed(BTN_B) && stack->count>1) {
				closeDirectory();
				total = top->entries->count;
				dirty = 1;
				// can_resume = 0;
				if (total>0) readyResume(top->entries->items[top->selected]);
			}
			else if (!lodor_badge_focused && PAD_justPressed(BTN_SELECT) && stack->count==1) {
				// lodor: SELECT on the main menu opens the LIBRARY SEARCH overlay.
				lodor_show_search = 1;
				Lodor_resetSearch();
				dirty = 1;
			}
		}
		
		if (dirty) {
			// lodor: native modal render paths (mirror show_version: own full-screen draw + flip).
			if (lodor_show_onboard) {
				// ONBOARDING WIZARD render — highest priority (owns the screen on a fresh
				// device). Keyboard sub-mode overrides the per-step screen.
				if (lodor_ob_kb_active) {
					Lodor_obDrawKeyboard(screen);
				} else if (lodor_onboard_step==LODOR_OB_WELCOME) {
					Lodor_obDrawWelcome(screen);
				} else if (lodor_onboard_step==LODOR_OB_WIFI) {
					// §2 [#38]: native Wi-Fi network picker (phase 0). Phase 1 (password) is drawn by
					// the shared keyboard path above (lodor_ob_kb_active), so this only renders the list.
					int wc = lodor_ob_wifi_list ? lodor_ob_wifi_list->count : 0;
					if (wc==0) {
						GFX_clear(screen);
						GFX_blitHardwareGroup(screen, 0);
						Lodor_obMessage(screen, "No Wi-Fi networks found.\n\nPress Y to scan again, or B to go back.");
						GFX_blitButtonGroup((char*[]){ "B","BACK", "Y","RESCAN", NULL }, 0, screen, 1);
						GFX_flip(screen);
					} else {
						// Paged render: draw only the visible scroll-window slice via a temporary view
						// Array (shallow-borrows Entry* pointers), mirroring the library/search list
						// paging so an arbitrary number of networks is navigable. B/A/Y handled in input.
						if (lodor_ob_wifi_end<=lodor_ob_wifi_start) {
							lodor_ob_wifi_start = 0;
							lodor_ob_wifi_end = (wc<(MAIN_ROW_COUNT-1))?wc:(MAIN_ROW_COUNT-1);
						}
						Array* view = Array_new(); // shallow: borrows Entry*, free with Array_free (NOT EntryArray_free)
						int view_sel = 0;
						for (int i=lodor_ob_wifi_start; i<lodor_ob_wifi_end && i<wc; i++) {
							if (i==lodor_ob_wifi_sel) view_sel = view->count;
							Array_push(view, lodor_ob_wifi_list->items[i]);
						}
						Lodor_drawList(screen, "Choose a Wi-Fi network", view, view_sel);
						Array_free(view); // shallow free only -- Entry* still owned by lodor_ob_wifi_list
					}
				} else if (lodor_onboard_step==LODOR_OB_SERVER) {
					Lodor_obDrawServerForm(screen);
					} else if (lodor_onboard_step==LODOR_OB_MODE) {
						Lodor_obDrawModeChooser(screen);
					} else if (lodor_onboard_step==LODOR_OB_LAN) {
						Lodor_obDrawLanForm(screen);
					} else if (lodor_onboard_step==LODOR_OB_TS_HOST) {
						// Tailscale connected: prompt for the *.ts.net host (keyboard owns the screen when open).
						GFX_clear(screen);
						GFX_blitHardwareGroup(screen, 0);
						char tmsg[400];
						snprintf(tmsg, sizeof(tmsg),
							"Tailscale connected!\n\nEnter your RomM's Tailscale address - its\nMagicDNS name, ending in .ts.net\n(e.g. romm.yournet.ts.net).\n\nAddress: %s",
							lodor_ob_host[0] ? lodor_ob_host : "(none)");
						Lodor_obMessage(screen, tmsg);
						GFX_blitButtonGroup((char*[]){ "B","BACK", "A","EDIT", "START","SAVE", NULL }, 1, screen, 1);
						GFX_flip(screen);
				} else if (lodor_onboard_step==LODOR_OB_PAIR) {
					GFX_clear(screen);
					GFX_blitHardwareGroup(screen, 0);
					char pmsg[320];
					snprintf(pmsg, sizeof(pmsg),
						"Pairing code\n\nIn RomM's web UI, create a client token and copy its 8-digit pair code.\n\nCode: %s",
						lodor_ob_code[0] ? lodor_ob_code : "(none)");
					Lodor_obMessage(screen, pmsg); // §3 overscan-safe
					GFX_blitButtonGroup((char*[]){ "B","BACK", "A","ENTER CODE", "START","PAIR", NULL }, 1, screen, 1);
					GFX_flip(screen);
				} else if (lodor_onboard_step==LODOR_OB_DEVICE) {
					GFX_clear(screen);
					GFX_blitHardwareGroup(screen, 0);
					char dmsg[320];
						snprintf(dmsg, sizeof(dmsg),
							"Device name\n\nName this handheld so your saves show which device they came from.\n\nName: %s",
							lodor_ob_name[0] ? lodor_ob_name : "(none)");
					Lodor_obMessage(screen, dmsg); // §3 overscan-safe
					GFX_blitButtonGroup((char*[]){ "B","BACK", "A","EDIT NAME", "START", "FINISH", NULL }, 1, screen, 1);
					GFX_flip(screen);
				} else if (lodor_onboard_step==LODOR_OB_LOGIN_USER || lodor_onboard_step==LODOR_OB_LOGIN_PASS) {
					// FEATURE 2: Add-Profile sign-in. The username/password keyboard owns the screen
					// (lodor_ob_kb_active above); this fallback shows only on the brief non-kb frame.
					GFX_clear(screen);
					GFX_blitHardwareGroup(screen, 0);
					Lodor_obMessage(screen, "Sign in to RomM\n\nUse your EXISTING RomM account.\nThis does not create a new account.");
					GFX_blitButtonGroup((char*[]){ "B","BACK", NULL }, 1, screen, 1);
					GFX_flip(screen);
				}
				dirty = 0;
			}
			else if (lodor_show_confirm) {
				char cmsg[512];
				if (lodor_confirm_kind==1)
					snprintf(cmsg, sizeof(cmsg),
						"Delete\n%s\nfrom device?\n\nA: Delete   B: Cancel", lodor_gamename);
				else if (lodor_confirm_kind==3)
					snprintf(cmsg, sizeof(cmsg),
						"%d save%s couldn't upload.\nThey're safe on the device.\nDismiss the reminder?\n\nA: Dismiss   B: Keep",
						lodor_confirm_stuck, lodor_confirm_stuck==1?"":"s");
				else
					snprintf(cmsg, sizeof(cmsg),
						"Flash back to %s\n(%s)?\n\nYour current save is kept first,\nso you can always come back.\n\nA: Flashback   B: Cancel",
						lodor_confirm_savewhen[0]?lodor_confirm_savewhen:"this point",
						lodor_confirm_savedev[0]?lodor_confirm_savedev:"server");
				GFX_clear(screen);
				GFX_blitHardwareGroup(screen, 0);
				GFX_blitMessage(font.large, cmsg, screen, &(SDL_Rect){0,0,screen->w,screen->h});
				GFX_blitButtonGroup((char*[]){ "B","BACK", "A","SELECT", NULL }, 1, screen, 1);
				GFX_flip(screen);
				dirty = 0;
			}
			else if (lodor_show_details) {
				char dmsg[512];
				char szbuf[64];
				if (lodor_filesize >= 1024*1024)
					snprintf(szbuf, sizeof(szbuf), "%ld MB", lodor_filesize/(1024*1024));
				else if (lodor_filesize >= 1024)
					snprintf(szbuf, sizeof(szbuf), "%ld KB", lodor_filesize/1024);
				else
					snprintf(szbuf, sizeof(szbuf), "%ld bytes", lodor_filesize);
				// §override (#144): surface a per-game emulator in Details — only when a
				// sidecar override is actually in effect (missing pak falls back silently).
				char lodor_emuline[160] = "";
				{
					char cur_path[256], cur[128], scpak[128];
					Lodor_resolveEmu(lodor_rompath, cur_path);
					Lodor_pakStem(cur_path, cur, sizeof(cur));
					Lodor_readEmuSidecar(lodor_rompath, scpak, sizeof(scpak), NULL, 0);
					if (scpak[0] && strcmp(scpak, cur)==0)
						snprintf(lodor_emuline, sizeof(lodor_emuline), "\nEmulator: %s (per-game)", cur);
				}
				snprintf(dmsg, sizeof(dmsg), "%s\n\n%s\nSize: %s%s",
					lodor_gamename, lodor_on_device ? "On device" : "Cloud",
					lodor_on_device ? szbuf : "-", lodor_emuline);
				GFX_clear(screen);
				GFX_blitHardwareGroup(screen, 0);
				// lodor §11 (box art): draw the game's cover (if any) in the upper area, then
				// place the details text below it. A game with no cover falls back to the
				// original full-screen centered text (Lodor_drawBoxArt returns 0) — graceful.
				int art_bottom = Lodor_drawBoxArt(screen, lodor_rompath);
				if (art_bottom > 0) {
					int ty = art_bottom + SCALE1(PADDING);
					int th = screen->h - ty - LODOR_OB_SAFE_BOTTOM;
					if (th < SCALE1(PILL_SIZE)) th = SCALE1(PILL_SIZE);
					GFX_blitMessage(font.large, dmsg, screen,
						&(SDL_Rect){ LODOR_OB_SAFE_SIDE, ty, screen->w - LODOR_OB_SAFE_SIDE*2, th });
				} else {
					GFX_blitMessage(font.large, dmsg, screen, &(SDL_Rect){0,0,screen->w,screen->h});
				}
				GFX_blitButtonGroup((char*[]){ "B","BACK", NULL }, 0, screen, 1);
				GFX_flip(screen);
				dirty = 0;
			}
			else if (lodor_show_saves) {
				if (!lodor_saves_items || lodor_saves_items->count==0) {
					GFX_clear(screen);
					GFX_blitHardwareGroup(screen, 0);
					GFX_blitMessage(font.large, "Nothing to flash back to yet", screen, &(SDL_Rect){0,0,screen->w,screen->h});
					GFX_blitButtonGroup((char*[]){ "B","BACK", NULL }, 0, screen, 1);
					GFX_flip(screen);
				} else {
					char stitle[320];
					snprintf(stitle, sizeof(stitle), "Flashback \xe2\x80\x94 %s", lodor_gamename);
					Lodor_drawList(screen, stitle, lodor_saves_items, lodor_saves_sel);
				}
				dirty = 0;
			}
			else if (lodor_show_feed) {
				// lodor: read-only Sync Feed list (mirrors the saves-list render path).
				if (!lodor_feed_items || lodor_feed_items->count==0) {
					GFX_clear(screen);
					GFX_blitHardwareGroup(screen, 0);
					GFX_blitMessage(font.large, "No saves on the server yet", screen, &(SDL_Rect){0,0,screen->w,screen->h});
					GFX_blitButtonGroup((char*[]){ "B","BACK", NULL }, 0, screen, 1);
					GFX_flip(screen);
				} else {
					Lodor_drawList(screen, "Sync Feed", lodor_feed_items, lodor_feed_sel);
				}
				dirty = 0;
			}
			else if (lodor_show_sync) {
				// lodor: build the ROUTINE Sync list each frame; Lodor_drawList draws + flips. The
				// list is 6 items (FIX #105 split Refresh Library into Update + Full), plus a 7th
				// "Refresh box art (background)" action (FIX 3 / #99) on platforms that may run the bg
				// cover-fetch (OFF on 128MB miyoomini). Order MUST match the lodor_sync_sel cases and
				// the count MUST match LODOR_SYNC_COUNT in the input handler.
				Array* sitems = Array_new();
				char queue_label[40];
				snprintf(queue_label, sizeof(queue_label), "Download Queue (%d)", Lodor_queueCount());
				char* labels[7] = { "Sync Now", queue_label, "Refresh Library (Update)", "Refresh Library (Full)", "Download BIOS", "Sync Feed", "Refresh box art (background)" };
				int nlabels = lodor_bg_covers_ok ? 7 : 6;
				for (int i=0; i<nlabels; i++) {
					Entry* e = Entry_new("", ENTRY_ROM);
					free(e->name); e->name = strdup(labels[i]);
					Array_push(sitems, e);
				}
				lodor_storage_active = 1; // FEATURE 1: storage line on the Sync title row only
				Lodor_drawList(screen, "Sync", sitems, lodor_sync_sel);
				lodor_storage_active = 0;
				EntryArray_free(sitems);
				dirty = 0;
			}
			else if (lodor_show_settings) {
				// lodor: build the fixed 7-item Lodor SETTINGS list each frame (Tools -> Lodor).
				Array* sitems = Array_new();
				char warm_label[48];
				snprintf(warm_label, sizeof(warm_label), "Keep WiFi warm: %s", lodor_wifi_warm ? "ON" : "OFF");
				char dots_label[48];
				snprintf(dots_label, sizeof(dots_label), "Quality dots: %s", lodor_quality_dots ? "ON" : "OFF");
				// MULTI-USER: Switch Profile shows the active profile inline; User badge is a toggle.
				char prof_label[80];
				if (lodor_profile_label[0]) snprintf(prof_label, sizeof(prof_label), "Switch User (%s)", lodor_profile_label);
				else snprintf(prof_label, sizeof(prof_label), "Switch User");
				char badge_label[48];
				snprintf(badge_label, sizeof(badge_label), "User badge: %s", lodor_user_badge ? "ON" : "OFF");
				char art_label[48];
				snprintf(art_label, sizeof(art_label), "Box art: %s", lodor_box_art ? "ON" : "OFF");
				char* labels[7] = { "Re-connect RomM", art_label, warm_label, dots_label, prof_label, badge_label, "RetroAchievements" };
				for (int i=0; i<7; i++) {
					Entry* e = Entry_new("", ENTRY_ROM);
					free(e->name); e->name = strdup(labels[i]);
					Array_push(sitems, e);
				}
				Lodor_drawList(screen, "Lodor Settings", sitems, lodor_settings_sel);
				EntryArray_free(sitems);
				dirty = 0;
			}
			else if (lodor_show_profiles) {
				// lodor MULTI-USER: render the profile switcher (built lists + "+ Add Profile").
				if (lodor_profile_items) Lodor_drawList(screen, "Switch User", lodor_profile_items, lodor_profiles_sel);
				else Lodor_drawMessage(screen, "No profiles");
				dirty = 0;
			}
			else if (lodor_show_ra) {
				// lodor: RetroAchievements overlay. While a field is being typed the shared keyboard
				// owns the screen (masked for the password); otherwise a single "Log in" row with the
				// current login state in the title ("Logged in as <user>" read from config.json).
				if (lodor_ob_kb_active) {
					Lodor_obDrawKeyboard(screen);
				} else {
					Array* ritems = Array_new();
					Entry* e = Entry_new("", ENTRY_ROM);
					free(e->name); e->name = strdup(lodor_ra_status[0] ? "Log in again" : "Log in");
					Array_push(ritems, e);
					char en_label[48];
					snprintf(en_label, sizeof(en_label), "RetroAchievements: %s", lodor_ra_enable ? "ON" : "OFF");
					Entry* e1 = Entry_new("", ENTRY_ROM);
					free(e1->name); e1->name = strdup(en_label);
					Array_push(ritems, e1);
					char hc_label[48];
					snprintf(hc_label, sizeof(hc_label), "Hardcore: %s", lodor_ra_hardcore ? "ON" : "OFF");
					Entry* e2 = Entry_new("", ENTRY_ROM);
					free(e2->name); e2->name = strdup(hc_label);
					Array_push(ritems, e2);
					char rtitle[128];
					if (lodor_ra_status[0]) snprintf(rtitle, sizeof(rtitle), "RetroAchievements \xE2\x80\x94 Logged in as %s", lodor_ra_status);
					else                    snprintf(rtitle, sizeof(rtitle), "RetroAchievements \xE2\x80\x94 not logged in");
					Lodor_drawList(screen, rtitle, ritems, lodor_ra_sel);
					EntryArray_free(ritems);
				}
				dirty = 0;
			}
			else if (lodor_show_switch) {
				// lodor §gameswitch (#149): full-screen preview + name/playtime caption.
				GFX_clear(screen);
				if (lodor_switch_count>0) {
					int lodor_si = lodor_switch_sel;
					// preview through the LRU loader (off-thread; grow small native-res shots
					// toward the screen). NULL while the decode is in flight -> text-only frame;
					// Lodor_artPollReady kicks a repaint when it lands. Text-only worst case.
					SDL_Surface* lodor_sw_shot = NULL;
					if (lodor_switch_shot[lodor_si][0])
						lodor_sw_shot = Lodor_artRequest(lodor_switch_shot[lodor_si], FIXED_WIDTH, FIXED_HEIGHT, 1);
					// warm the neighbors into the bounded prefetch slots (LEFT/RIGHT feel instant)
					for (int lodor_d=-1; lodor_d<=1; lodor_d+=2) {
						int lodor_ni = (lodor_si+lodor_d+lodor_switch_count)%lodor_switch_count;
						if (lodor_ni!=lodor_si && lodor_switch_shot[lodor_ni][0])
							Lodor_artPrefetch(lodor_switch_shot[lodor_ni], FIXED_WIDTH, FIXED_HEIGHT, 1);
					}
					if (lodor_sw_shot) {
						int lodor_ax = (screen->w - lodor_sw_shot->w)/2; if (lodor_ax<0) lodor_ax=0;
						int lodor_ay = (screen->h - lodor_sw_shot->h)/2; if (lodor_ay<0) lodor_ay=0;
						SDL_BlitSurface(lodor_sw_shot, NULL, screen, &(SDL_Rect){lodor_ax,lodor_ay});
						// §artcache: cache-owned — do NOT free.
					}
					// bottom band: name (+ playtime when totals.tsv has a row) on a solid strip
					char lodor_sw_txt[420];
					if (lodor_switch_cap[lodor_si][0])
						snprintf(lodor_sw_txt, sizeof(lodor_sw_txt), "%s\n%s", lodor_switch_name[lodor_si], lodor_switch_cap[lodor_si]);
					else
						snprintf(lodor_sw_txt, sizeof(lodor_sw_txt), "%s", lodor_switch_name[lodor_si]);
					int lodor_band_h = SCALE1(PILL_SIZE*2);
					int lodor_band_y = screen->h - SCALE1(PILL_SIZE) - lodor_band_h;
					SDL_FillRect(screen, &(SDL_Rect){0, lodor_band_y, screen->w, lodor_band_h}, 0);
					GFX_blitMessage(font.large, lodor_sw_txt, screen, &(SDL_Rect){0, lodor_band_y, screen->w, lodor_band_h});
					// top strip: position indicator ("2/8")
					char lodor_sw_pos[32];
					snprintf(lodor_sw_pos, sizeof(lodor_sw_pos), "%d/%d", lodor_si+1, lodor_switch_count);
					SDL_FillRect(screen, &(SDL_Rect){0, 0, screen->w, SCALE1(PILL_SIZE)}, 0);
					GFX_blitMessage(font.small ? font.small : font.large, lodor_sw_pos, screen, &(SDL_Rect){0, 0, screen->w, SCALE1(PILL_SIZE)});
					GFX_blitButtonGroup((char*[]){ "B","BACK", "A","RESUME", NULL }, 1, screen, 1);
				}
				else { // defensive — the trigger only opens a non-empty switcher
					GFX_blitMessage(font.large, "Nothing recent yet", screen, &(SDL_Rect){0,0,screen->w,screen->h});
					GFX_blitButtonGroup((char*[]){ "B","BACK", NULL }, 0, screen, 1);
				}
				GFX_flip(screen);
				dirty = 0;
			}
			else if (lodor_show_emupick) {
				// §override (#144): Emulator picker render — actions-modal chrome.
				char etitle[320];
				snprintf(etitle, sizeof(etitle), "Emulator \xe2\x80\x94 %s", lodor_gamename);
				Lodor_drawList(screen, etitle, lodor_emupick_items, lodor_emupick_sel);
				dirty = 0;
			}
			else if (lodor_show_actions) {
				char atitle[320];
				snprintf(atitle, sizeof(atitle), "Options: %s", lodor_gamename);
				Lodor_drawList(screen, atitle, lodor_action_items, lodor_action_sel);
				dirty = 0;
			}
			else if (lodor_show_search) {
				// lodor: LIBRARY SEARCH render. Phase 0 = keyboard, phase 1 = results.
				if (lodor_search_phase==0) {
					Lodor_drawKeyboard(screen);
				}
				else {
					int rc = lodor_search_results ? lodor_search_results->count : 0;
					if (rc==0) {
						GFX_clear(screen);
						GFX_blitHardwareGroup(screen, 0);
						GFX_blitMessage(font.large, "No matches", screen, &(SDL_Rect){0,0,screen->w,screen->h});
						GFX_blitButtonGroup((char*[]){ "B","BACK", NULL }, 0, screen, 1);
						GFX_flip(screen);
					}
					else {
						// title shows the count (and the cap note when we stopped at LODOR_SEARCH_CAP).
						char rtitle[96];
						if (lodor_search_capped)
							snprintf(rtitle, sizeof(rtitle), "%d results (showing first %d)", rc, LODOR_SEARCH_CAP);
						else
							snprintf(rtitle, sizeof(rtitle), "%d result%s", rc, rc==1?"":"s");
						// clamp paging window, then draw the visible slice via a temporary view Array.
						if (lodor_search_end<=lodor_search_start) {
							lodor_search_start = 0;
							lodor_search_end = (rc<(MAIN_ROW_COUNT-1))?rc:(MAIN_ROW_COUNT-1);
						}
						Array* view = Array_new(); // shallow: borrows Entry* pointers, freed with Array_free (NOT EntryArray_free)
						int view_sel = 0;
						for (int i=lodor_search_start; i<lodor_search_end && i<rc; i++) {
							if (i==lodor_search_sel) view_sel = view->count;
							Array_push(view, lodor_search_results->items[i]);
						}
						Lodor_drawList(screen, rtitle, view, view_sel);
						Array_free(view); // shallow free only -- Entry* still owned by lodor_search_results
					}
				}
				dirty = 0;
			}
			else {
			GFX_clear(screen);
			
			int ox;
			int oy;
			
			// simple thumbnail support a thumbnail for a file or folder named NAME.EXT needs a corresponding /.res/NAME.EXT.png 
			// that is no bigger than platform FIXED_HEIGHT x FIXED_HEIGHT
			int had_thumb = 0;
			int lodor_cover_shown = 0; // lodor FIX 1 (#103): set when the box-art cover panel claims the right side this frame
			if (!show_version && total>0) {
				Entry* entry = top->entries->items[top->selected];
				char res_path[MAX_PATH];
				
				char res_root[MAX_PATH];
				strcpy(res_root, entry->path);
				
				char tmp_path[MAX_PATH];
				strcpy(tmp_path, entry->path);
				char* res_name = strrchr(tmp_path, '/') + 1;

				char* tmp = strrchr(res_root, '/');
				tmp[0] = '\0';
				
				sprintf(res_path, "%s/.res/%s.png", res_root, res_name);
				LOG_info("res_path: %s\n", res_path);
				if (exists(res_path)) {
					// §artcache (#148): folder thumbs ride the same async LRU as covers — the
					// synchronous IMG_Load stall on selection change is gone. NULL while the
					// decode is in flight (no thumb that frame; Lodor_artPollReady repaints when
					// it lands). Oversized thumbs (spec says <= FIXED_HEIGHT square) now
					// downscale-on-insert instead of clipping. Cache-owned — do NOT free.
					SDL_Surface* thumb = Lodor_artRequest(res_path, FIXED_HEIGHT, FIXED_HEIGHT, 0);
					if (thumb) {
						had_thumb = 1;
						ox = MAX(FIXED_WIDTH - FIXED_HEIGHT, (FIXED_WIDTH - thumb->w));
						oy = (FIXED_HEIGHT - thumb->h) / 2;
						SDL_BlitSurface(thumb, NULL, screen, &(SDL_Rect){ox,oy});
					}
				}
				// lodor FIX 1 (box art on the main list): static cover panel for the HIGHLIGHTED game.
				// When no folder .res thumb claimed the right panel AND box art is enabled AND the
				// highlighted entry is a game with a saved .media cover, show that cover in the same
				// right-side panel — the art simply follows the selection (NextUI-style). NO carousel,
				// NO Continue-switcher, NO diagonal: a single static cover. Reuses Lodor_mediaPath +
				// the async art loader (Lodor_artRequest): returns NULL until the PNG decodes off the
				// UI thread, and Lodor_artPollReady() kicks a repaint when it lands, so the list never
				// blocks on a decode. The async cache OWNS the surface (do NOT free it here). Gated on
				// lodor_box_art (fetch_covers OFF => no panel). Sharing ox/had_thumb reflows the list
				// text to the left exactly like the .res thumb does.
				if (!had_thumb && lodor_box_art && entry->type==ENTRY_ROM) {
					char media[MAX_PATH];
					if (Lodor_mediaPath(entry->path, media, sizeof(media)) && exists(media)) {
						SDL_Surface* cover = Lodor_artRequest(media, FIXED_HEIGHT, FIXED_HEIGHT, 0);
						if (cover) {
							had_thumb = 1;
							ox = MAX(FIXED_WIDTH - FIXED_HEIGHT, (FIXED_WIDTH - cover->w));
							oy = (FIXED_HEIGHT - cover->h) / 2;
							// subtle 2px frame so a light-edged cover reads as a clean panel, not a floating sprite.
							Uint32 _fr = SDL_MapRGB(screen->format, 0x3A, 0x36, 0x30);
							SDL_FillRect(screen, &(SDL_Rect){ox-2, oy-2, cover->w+4, 2}, _fr);
							SDL_FillRect(screen, &(SDL_Rect){ox-2, oy+cover->h, cover->w+4, 2}, _fr);
							SDL_FillRect(screen, &(SDL_Rect){ox-2, oy-2, 2, cover->h+4}, _fr);
							SDL_FillRect(screen, &(SDL_Rect){ox+cover->w, oy-2, 2, cover->h+4}, _fr);
							SDL_BlitSurface(cover, NULL, screen, &(SDL_Rect){ox,oy});
							lodor_cover_shown = 1; // lodor FIX 1 (#103): cover claims the right margin -> suppress the watermark this frame
							// §artcache: do NOT free — surface is owned by the LRU cache.
						}
					}
				}
				// §artcache (#148): idle prefetch of the neighbors' covers (selected +/- 1) so a
				// steady scroll finds the next cover already decoded. Bounded — the two prefetch
				// slots drop silently when busy; already-cached paths are skipped inside.
				if (lodor_box_art) {
					for (int lodor_d=-1; lodor_d<=1; lodor_d+=2) {
						int lodor_ni = top->selected + lodor_d;
						if (lodor_ni<0 || lodor_ni>=top->entries->count) continue;
						Entry* lodor_ne = top->entries->items[lodor_ni];
						if (lodor_ne->type!=ENTRY_ROM) continue;
						char lodor_nmedia[MAX_PATH];
						if (Lodor_mediaPath(lodor_ne->path, lodor_nmedia, sizeof(lodor_nmedia)) && exists(lodor_nmedia))
							Lodor_artPrefetch(lodor_nmedia, FIXED_HEIGHT, FIXED_HEIGHT, 0);
					}
				}
			}
			
			int ow = GFX_blitHardwareGroup(screen, show_setting);
			
			if (show_version) {
				if (!version) {
					char release[256];
					getFile(ROOT_SYSTEM_PATH "/version.txt", release, 256);
					
					char *tmp,*commit;
					commit = strrchr(release, '\n');
					commit[0] = '\0';
					commit = strrchr(release, '\n')+1;
					tmp = strchr(release, '\n');
					tmp[0] = '\0';
					
					// TODO: not sure if I want bare PLAT_* calls here
					char* extra_key = "Model";
					char* extra_val = PLAT_getModel(); 
					
					SDL_Surface* release_txt = TTF_RenderUTF8_Blended(font.large, "LodorOS", COLOR_DARK_TEXT);
					SDL_Surface* version_txt = TTF_RenderUTF8_Blended(font.large, release, COLOR_WHITE);
					SDL_Surface* commit_txt = TTF_RenderUTF8_Blended(font.large, "Commit", COLOR_DARK_TEXT);
					SDL_Surface* hash_txt = TTF_RenderUTF8_Blended(font.large, commit, COLOR_WHITE);
					
					SDL_Surface* key_txt = TTF_RenderUTF8_Blended(font.large, extra_key, COLOR_DARK_TEXT);
					SDL_Surface* val_txt = TTF_RenderUTF8_Blended(font.large, extra_val, COLOR_WHITE);
					
					int l_width = 0;
					int r_width = 0;
					
					if (release_txt->w>l_width) l_width = release_txt->w;
					if (commit_txt->w>l_width) l_width = commit_txt->w;
					if (key_txt->w>l_width) l_width = commit_txt->w;

					if (version_txt->w>r_width) r_width = version_txt->w;
					if (hash_txt->w>r_width) r_width = hash_txt->w;
					if (val_txt->w>r_width) r_width = val_txt->w;
					
					#define VERSION_LINE_HEIGHT 24
					int x = l_width + SCALE1(8);
					int w = x + r_width;
					int h = SCALE1(VERSION_LINE_HEIGHT*4);
					version = SDL_CreateRGBSurface(0,w,h,16,0,0,0,0);
					
					SDL_BlitSurface(release_txt, NULL, version, &(SDL_Rect){0, 0});
					SDL_BlitSurface(version_txt, NULL, version, &(SDL_Rect){x,0});
					SDL_BlitSurface(commit_txt, NULL, version, &(SDL_Rect){0,SCALE1(VERSION_LINE_HEIGHT)});
					SDL_BlitSurface(hash_txt, NULL, version, &(SDL_Rect){x,SCALE1(VERSION_LINE_HEIGHT)});
					
					SDL_BlitSurface(key_txt, NULL, version, &(SDL_Rect){0,SCALE1(VERSION_LINE_HEIGHT*3)});
					SDL_BlitSurface(val_txt, NULL, version, &(SDL_Rect){x,SCALE1(VERSION_LINE_HEIGHT*3)});
					
					SDL_FreeSurface(release_txt);
					SDL_FreeSurface(version_txt);
					SDL_FreeSurface(commit_txt);
					SDL_FreeSurface(hash_txt);
					SDL_FreeSurface(key_txt);
					SDL_FreeSurface(val_txt);
				}
				SDL_BlitSurface(version, NULL, screen, &(SDL_Rect){(screen->w-version->w)/2,(screen->h-version->h)/2});
				
				// buttons (duped and trimmed from below)
				if (show_setting && !GetHDMI()) GFX_blitHardwareHints(screen, show_setting);
				else GFX_blitButtonGroup((char*[]){ BTN_SLEEP==BTN_POWER?"POWER":"MENU","SLEEP",  NULL }, 0, screen, 0);
				
				GFX_blitButtonGroup((char*[]){ "B","BACK",  NULL }, 0, screen, 1);
			}
			else {
				// list
				if (total>0) {
					int selected_row = top->selected - top->start;
					for (int i=top->start,j=0; i<top->end; i++,j++) {
						Entry* entry = top->entries->items[i];
						char* entry_name = entry->name;
						char* entry_unique = entry->unique;
						int available_width = (had_thumb && j!=selected_row ? ox : screen->w) - SCALE1(PADDING * 2);
						if (i==top->start && !(had_thumb && j!=selected_row)) available_width -= ow; // 
					
						SDL_Color text_color = COLOR_WHITE;
						// lodor: the injected "Saves Pending" banner row (ENTRY_PAK whose name starts
						// with "There are "/"There is ") renders in the red accent so it reads as an alert.
						if (entry->type==ENTRY_PAK && entry_name &&
							(strncmp(entry_name,"There are ",10)==0 || strncmp(entry_name,"There is ",9)==0)) {
							text_color = COLOR_ACCENT;
						}
						// lodor: dim cloud-only games (0-byte stubs) so on-device games stand out at a glance.
						int hoardui_cloud = (entry->type==ENTRY_ROM);
						if (hoardui_cloud) { struct stat hoardui_st; hoardui_cloud = (stat(entry->path, &hoardui_st)==0 && hoardui_st.st_size==0); }
						if (hoardui_cloud) text_color = (SDL_Color){ 0x6E, 0x69, 0x60, 0xFF }; // lodor: muted cloud-only marker
					
						trimSortingMeta(&entry_name);
					
						char display_name[256];
						int text_width = GFX_truncateText(font.large, entry_unique ? entry_unique : entry_name, display_name, available_width, SCALE1(BUTTON_PADDING*2));
						int max_width = MIN(available_width, text_width);
						if (j==selected_row) {
							GFX_blitPill(ASSET_WHITE_PILL, screen, &(SDL_Rect){
								SCALE1(PADDING),
								SCALE1(PADDING+(j*PILL_SIZE)),
								max_width,
								SCALE1(PILL_SIZE)
							});
							text_color = COLOR_BLACK;
						}
						else if (entry->unique) {
							trimSortingMeta(&entry_unique);
							char unique_name[256];
							GFX_truncateText(font.large, entry_unique, unique_name, available_width, SCALE1(BUTTON_PADDING*2));
						
							SDL_Surface* text = TTF_RenderUTF8_Blended(font.large, unique_name, COLOR_DARK_TEXT);
							SDL_BlitSurface(text, &(SDL_Rect){
								0,
								0,
								max_width-SCALE1(BUTTON_PADDING*2),
								text->h
							}, screen, &(SDL_Rect){
								SCALE1(PADDING+BUTTON_PADDING),
								SCALE1(PADDING+(j*PILL_SIZE)+4)
							});
						
							GFX_truncateText(font.large, entry_name, display_name, available_width, SCALE1(BUTTON_PADDING*2));
						}
						SDL_Surface* text = TTF_RenderUTF8_Blended(font.large, display_name, text_color);
						SDL_BlitSurface(text, &(SDL_Rect){
							0,
							0,
							max_width-SCALE1(BUTTON_PADDING*2),
							text->h
						}, screen, &(SDL_Rect){
							SCALE1(PADDING+BUTTON_PADDING),
							SCALE1(PADDING+(j*PILL_SIZE)+4)
						});
						SDL_FreeSurface(text);

						// FIX 3 + #98: per-system performance tier dot — ROOT menu, system folders only
						// (Roms/<system> dirs). Rendered in the LEFT gutter (the BUTTON_PADDING gap
						// between the pill's left edge and the system name) so the dot sits immediately
						// to the LEFT of the console name (#98) instead of right-aligned. This drops the
						// old watermark/thumb right-edge math entirely — the dot no longer competes with
						// the box-art panel or the brand mark. Opt-in: only when SHOW_QUALITY_DOTS is
						// enabled. Unknown/unmapped systems get no dot (never a wrong mark).
						if (lodor_quality_dots
						    && exactMatch(top->path, SDCARD_PATH) && entry->type==ENTRY_DIR
						    && prefixMatch(ROMS_PATH, entry->path)) {
							int tier = Lodor_tierForSystemPath(entry->path);
							if (tier >= 0) {
								int ds = SCALE1(8);
								// center the dot in the gutter [PADDING .. PADDING+BUTTON_PADDING),
								// i.e. left of the name which starts at SCALE1(PADDING+BUTTON_PADDING).
								int dx = SCALE1(PADDING) + (SCALE1(BUTTON_PADDING) - ds)/2;
								int dy = SCALE1(PADDING + (j*PILL_SIZE)) + (SCALE1(PILL_SIZE)-ds)/2;
								SDL_FillRect(screen, &(SDL_Rect){dx, dy, ds, ds},
								             Lodor_tierColor(screen, tier));
							}
						}
					}
				}
				else {
					// TODO: for some reason screen's dimensions end up being 0x0 in GFX_blitMessage...
					GFX_blitMessage(font.large, "Empty folder", screen, &(SDL_Rect){0,0,screen->w,screen->h}); //, NULL);
				}
			
				// buttons
				if (show_setting && !GetHDMI()) GFX_blitHardwareHints(screen, show_setting);
				else if (can_resume) GFX_blitButtonGroup((char*[]){ "X","RESUME",  NULL }, 0, screen, 0);
				// lodor: on the root menu, the left pill hints SELECT->Search (replaces the power/sleep
				// hint — power-off is universally understood). Subfolders keep the power/sleep hint since
				// SELECT only searches at root.
				// lodor §gameswitch (#149): advertise the switcher next to Search at root when
				// there is anything recent to switch to (X still opens it in subfolders too —
				// the left pill there keeps the power/sleep hint).
				else if (stack->count==1 && recents && recents->count>0)
					GFX_blitButtonGroup((char*[]){ "SELECT","SEARCH", "X","GAMES", NULL }, 0, screen, 0);
				else if (stack->count==1) GFX_blitButtonGroup((char*[]){ "SELECT","SEARCH",  NULL }, 0, screen, 0);
				else GFX_blitButtonGroup((char*[]){ 
					BTN_SLEEP==BTN_POWER?"POWER":"MENU",
					BTN_SLEEP==BTN_POWER||simple_mode?"SLEEP":"INFO",  
					NULL }, 0, screen, 0);
			
				if (total==0) {
					if (stack->count>1) {
						GFX_blitButtonGroup((char*[]){ "B","BACK",  NULL }, 0, screen, 1);
					}
				}
				else {
					if (stack->count>1) {
						(((Entry*)top->entries->items[top->selected])->type==ENTRY_ROM) ? GFX_blitButtonGroup((char*[]){ "B","BACK", "Y","OPTIONS", "A","OPEN", NULL }, 2, screen, 1) : GFX_blitButtonGroup((char*[]){ "B","BACK", "A","OPEN", NULL }, 1, screen, 1);
					}
					else {
						(((Entry*)top->entries->items[top->selected])->type==ENTRY_ROM) ? GFX_blitButtonGroup((char*[]){ "Y","OPTIONS", "A","OPEN", NULL }, 1, screen, 1) : GFX_blitButtonGroup((char*[]){ "A","OPEN", NULL }, 0, screen, 1);
					}
				}
			}

			// lodor: subtle vertical "LodorOS" brand mark down the right black margin.
			// Only on the normal file-browser (not the version card); never over rows/status.
			if (!show_version) {
				SDL_Surface* wm = Lodor_getWatermark();
				if (wm) {
					int wmx = screen->w - wm->w - SCALE1(PADDING);
					int wmy = (screen->h - wm->h) / 2; // vertically centered in the content area
					// lodor FIX 1 (#103): when a box-art cover panel claims the right side this frame,
					// the vertical watermark would overprint the cover's right edge (both sit at the far
					// right margin). Suppress ONLY the watermark blit in that case. Covers appear at
					// depth>1; the pending/synced badge below is root-only (stack->count==1), so it is
					// never affected — the standalone sync badge stays intact (earlier user feedback).
					if (!lodor_cover_shown)
						SDL_BlitSurface(wm, NULL, screen, &(SDL_Rect){wmx, wmy});
					// lodor: badge inline above the watermark. PRECEDENCE: an offline pending
					// backlog ALWAYS wins (it's actionable — RIGHT focuses it, A uploads). Only
					// when there's nothing pending do we flash the transient "synced ✓" confirmation
					// (a just-landed direct push). At root depth only.
					int bnp = (stack && stack->count==1) ? Lodor_pendingCount() : 0;
					if (bnp > 0) {
						Lodor_drawBadge(screen, wmx, wmy, wm->w, bnp, lodor_badge_focused);
					}
					else if (stack && stack->count==1) {
						long _sts=0; int _scount=0;
						if (Lodor_syncedFresh(&_sts, &_scount)) {
							Lodor_drawSyncedBadge(screen, wmx, wmy, wm->w, _scount);
							lodor_synced_shown_ts = _sts; // remember to ack on the next input
						}
					}
				}
			}

			// lodor MULTI-USER: the user badge (active profile initial, top-right corner). Drawn
			// at root only, when enabled AND a profile is active. The "who am I synced as" cue.
			int _ub_shown = (!show_version && lodor_user_badge && stack && stack->count==1 && Lodor_profileInitial()!='\0');
			if (_ub_shown) Lodor_drawUserBadge(screen);
			// FIX 3 (#99): the background cover-fetch status pill (UPPER-RIGHT). Root only, and only
			// on platforms that may run the feature (OFF on 128MB miyoomini). Reserve room for the
			// user badge when it's shown so the two never overlap. No fake progress — drawn only when
			// the engine wrote a live bg-task.status (running/paused/error, or a fresh done).
			if (!show_version && lodor_bg_covers_ok && stack && stack->count==1) {
				LodorBgStatus _bg;
				if (Lodor_readBgStatus(&_bg))
					Lodor_drawBgPill(screen, &_bg, _ub_shown ? SCALE1(BUTTON_SIZE + PADDING) : 0);
			}
			Lodor_drawToast(screen); // lodor §toast: transient sync/offline message, bottom-center

			GFX_flip(screen);
			dirty = 0;
			} // lodor: end of normal (non-modal) render branch
		}
		else GFX_sync();
		
		// if (!first_draw) {
		// 	first_draw = SDL_GetTicks();
		// 	LOG_info("- first draw: %lu\n", first_draw - main_begin);
		// }
		
		// handle HDMI change
		static int had_hdmi = -1;
		int has_hdmi = GetHDMI();
		if (had_hdmi==-1) had_hdmi = has_hdmi;
		if (has_hdmi!=had_hdmi) {
			had_hdmi = has_hdmi;

			Entry* entry = top->entries->items[top->selected];
			LOG_info("restarting after HDMI change... (%s)\n", entry->path);
			saveLast(entry->path); // NOTE: doesn't work in Recents (by design)
			sleep(4);
			quit = 1;
		}
	}
	
	if (version) SDL_FreeSurface(version);
	Lodor_freeActions(); // lodor: release modal item lists (no leaks on quit/launch)
	Lodor_freeSaves();
	Lodor_freeFeed();
	Lodor_freeProfiles(); // lodor MULTI-USER: release the profile switcher list
	Lodor_freeWatermark(); // lodor: release cached brand watermark
	Lodor_artQuit();       // §artcache (#148): stop + join the cover-decode worker

	Menu_quit();
	PWR_quit();
	PAD_quit();
	GFX_quit();
	QuitSettings();
}