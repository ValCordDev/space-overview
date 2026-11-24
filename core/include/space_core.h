#ifndef SPACE_CORE_H
#define SPACE_CORE_H
#include <stdint.h>
#include <stdbool.h>
#define SO_NONE UINT32_MAX
typedef struct SoScan SoScan;
typedef struct { uint64_t items, bytes, denied; bool done; } SoProgress;
// id is SO_NONE for files. name is only valid during the callback.
typedef struct { const uint8_t *name; uint64_t name_len, size, items; int64_t mtime; uint32_t id; uint32_t parent; bool denied; } SoEntry;
typedef void (*SoCallback)(void *ctx, const SoEntry *entry);
SoScan *so_scan_start(const char *path, uint32_t threads);
void so_scan_progress(const SoScan *s, SoProgress *out);
// Cancels, waits for the workers, and frees.
void so_scan_free(SoScan *s);
// Everything below returns nothing until the scan is done.
uint32_t so_find(const SoScan *s, const char *relative_path);
bool so_entry(const SoScan *s, uint32_t id, void *ctx, SoCallback cb);
void so_child_dirs(const SoScan *s, uint32_t id, void *ctx, SoCallback cb);
// Reads the files of a folder live from disk.
void so_child_files(const SoScan *s, uint32_t id, void *ctx, SoCallback cb);
void so_large_files(const SoScan *s, void *ctx, SoCallback cb);
// Measures a path as it is now. frees is a lower bound (clones and snapshots share data).
typedef struct { uint64_t size, frees, items, denied; } SoMeasure;
void so_measure(const char *path, SoMeasure *out);
// Keep the scanned tree in step with changes the app made on disk.
void so_set_dir_gone(const SoScan *s, uint32_t id, bool gone);
void so_set_file_gone(const SoScan *s, uint32_t parent, const char *name, uint64_t size, bool gone);
void so_rename_dir(const SoScan *s, uint32_t id, const char *name);
void so_rename_file(const SoScan *s, uint32_t parent, const char *old_name, const char *new_name);
void so_add_dir(const SoScan *s, uint32_t parent, const char *name, int64_t mtime);
#endif
