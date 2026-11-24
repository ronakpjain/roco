#include "kernel_fs.h"

/*
 * roco_cc has no structs, so the on-RAM inode table is a set of parallel
 * arrays. The arena is placed in a fixed, supervisor-only SDRAM window;
 * only this file touches it.
 */

#ifndef FS_RAM
#define FS_RAM 0x100c0000u
#endif
#define FS_BYTES 0x30000u
#define FS_BLOCKS (FS_BYTES / FS_BLOCK_SIZE)
#define FS_MAP_WORDS ((FS_BLOCKS + 31u) / 32u)
#define FS_MAX_INODES 64u
#define FS_MAX_CHAIN 16u

extern void spin_lock(unsigned *lock);
extern void spin_unlock(unsigned *lock);

static unsigned ino_used[FS_MAX_INODES];
static unsigned ino_type[FS_MAX_INODES];
static unsigned ino_parent[FS_MAX_INODES];
static unsigned ino_size[FS_MAX_INODES];
static unsigned ino_start[FS_MAX_INODES];
static unsigned ino_blocks[FS_MAX_INODES];
static char ino_name[FS_MAX_INODES][FS_MAX_NAME];

static unsigned block_map[FS_MAP_WORDS];
static unsigned free_block_count;
static unsigned fs_lock_word;
static char component[FS_MAX_NAME];

static unsigned k_strlen(const char *s)
{
    unsigned n = 0;
    while (s[n] != 0)
        ++n;
    return n;
}

static void k_strcpy(char *dst, const char *src)
{
    while (*src != 0)
        *dst++ = *src++;
    *dst = 0;
}

static void k_strncpy(char *dst, const char *src, unsigned cap)
{
    unsigned i = 0;
    if (cap == 0)
        return;
    while (i + 1 < cap && src[i] != 0) {
        dst[i] = src[i];
        ++i;
    }
    dst[i] = 0;
}

static int k_streq(const char *a, const char *b)
{
    while (*a == *b) {
        if (*a == 0)
            return 1;
        ++a;
        ++b;
    }
    return 0;
}

static int k_streq_len(const char *a, const char *b, unsigned n)
{
    unsigned i = 0;
    while (i < n) {
        if (a[i] != b[i])
            return 0;
        ++i;
    }
    return a[n] == 0;
}

static void k_memcpy(void *dst, const void *src, unsigned len)
{
    char *d = (char *)dst;
    const char *s = (const char *)src;
    while (len != 0) {
        *d++ = *s++;
        --len;
    }
}

static void k_memset(void *dst, unsigned value, unsigned len)
{
    char *d = (char *)dst;
    while (len != 0) {
        *d++ = (char)value;
        --len;
    }
}

static char *block_ptr(unsigned block)
{
    return (char *)(unsigned long)(FS_RAM + block * FS_BLOCK_SIZE);
}

static int block_used(unsigned block)
{
    return (block_map[block >> 5] & (1u << (block & 31u))) != 0;
}

static void block_mark(unsigned block, unsigned used)
{
    if (used)
        block_map[block >> 5] |= 1u << (block & 31u);
    else
        block_map[block >> 5] &= ~(1u << (block & 31u));
}

static int alloc_blocks(unsigned count)
{
    unsigned start;
    unsigned i;

    if (count == 0)
        return 0;
    if (count > free_block_count)
        return FS_ENOSPC;
    for (start = 0; start + count <= FS_BLOCKS; ++start) {
        i = 0;
        while (i < count && !block_used(start + i))
            ++i;
        if (i == count) {
            for (i = 0; i < count; ++i)
                block_mark(start + i, 1);
            free_block_count -= count;
            return (int)start;
        }
        start += i;
    }
    return FS_ENOSPC;
}

static void release_blocks(unsigned start, unsigned count)
{
    unsigned i;
    for (i = 0; i < count; ++i)
        block_mark(start + i, 0);
    free_block_count += count;
}

static int inode_alloc(unsigned parent, const char *name, unsigned type)
{
    unsigned i;
    unsigned len = k_strlen(name);

    if (len == 0 || len >= FS_MAX_NAME)
        return FS_EINVAL;
    for (i = 1; i < FS_MAX_INODES; ++i) {
        if (ino_used[i])
            continue;
        ino_used[i] = 1;
        ino_type[i] = type;
        ino_parent[i] = parent;
        ino_size[i] = 0;
        ino_start[i] = 0;
        ino_blocks[i] = 0;
        k_strncpy(ino_name[i], name, FS_MAX_NAME);
        return (int)i;
    }
    return FS_ENOSPC;
}

static int child_find(unsigned dir, const char *name, unsigned len)
{
    unsigned i;
    for (i = 1; i < FS_MAX_INODES; ++i) {
        if (!ino_used[i] || ino_parent[i] != dir)
            continue;
        if (k_streq_len(ino_name[i], name, len))
            return (int)i;
    }
    return FS_ENOENT;
}

static int dir_is_empty(unsigned dir)
{
    unsigned i;
    for (i = 1; i < FS_MAX_INODES; ++i) {
        if (ino_used[i] && ino_parent[i] == dir)
            return 0;
    }
    return 1;
}

static int lookup_locked(int cwd, const char *path)
{
    const char *p = path;
    int cur;
    unsigned guard = 0;
    unsigned n;

    if (path == 0 || *path == 0)
        return FS_ENOENT;
    cur = *path == '/' ? 0 : cwd;
    while (*p == '/')
        ++p;
    while (*p != 0) {
        n = 0;
        while (*p != 0 && *p != '/') {
            if (n + 1 >= FS_MAX_NAME)
                return FS_EINVAL;
            component[n++] = *p++;
        }
        component[n] = 0;
        while (*p == '/')
            ++p;
        if (k_streq(component, "."))
            continue;
        if (k_streq(component, "..")) {
            cur = (int)ino_parent[cur];
            continue;
        }
        if (ino_type[cur] != FS_TYPE_DIR)
            return FS_ENOTDIR;
        cur = child_find((unsigned)cur, component, n);
        if (cur < 0)
            return cur;
        if (++guard > FS_MAX_INODES)
            return FS_EINVAL;
    }
    return cur;
}

/*
 * Split a path into its parent directory and final component, then
 * resolve the parent relative to cwd.
 */
static int resolve_parent(int cwd, const char *path, char *leaf, unsigned cap)
{
    unsigned len = k_strlen(path);
    unsigned cut = len;
    unsigned i;
    char parent[FS_MAX_PATH];

    if (len == 0 || len >= FS_MAX_PATH)
        return FS_EINVAL;
    while (cut > 0 && path[cut - 1] != '/')
        --cut;
    i = 0;
    while (path[cut + i] != 0) {
        if (i + 1 >= cap)
            return FS_EINVAL;
        leaf[i] = path[cut + i];
        ++i;
    }
    leaf[i] = 0;
    if (i == 0 || k_streq(leaf, ".") || k_streq(leaf, ".."))
        return FS_EINVAL;
    if (cut == 0)
        return cwd;
    if (cut == 1)
        return 0;
    for (i = 0; i + 1 < cut; ++i)
        parent[i] = path[i];
    parent[cut - 1] = 0;
    return lookup_locked(cwd, parent);
}

static int create_locked(int cwd, const char *path, int type)
{
    char leaf[FS_MAX_NAME];
    int parent = resolve_parent(cwd, path, leaf, FS_MAX_NAME);

    if (parent < 0)
        return parent;
    if (ino_type[parent] != FS_TYPE_DIR)
        return FS_ENOTDIR;
    if (child_find((unsigned)parent, leaf, k_strlen(leaf)) >= 0)
        return FS_EEXIST;
    return inode_alloc((unsigned)parent, leaf, (unsigned)type);
}

static int truncate_locked(int ino)
{
    if (ino <= 0 || !ino_used[ino])
        return FS_EBAD;
    if (ino_type[ino] != FS_TYPE_FILE)
        return FS_EISDIR;
    if (ino_blocks[ino] != 0)
        release_blocks(ino_start[ino], ino_blocks[ino]);
    ino_start[ino] = 0;
    ino_blocks[ino] = 0;
    ino_size[ino] = 0;
    return 0;
}

static int write_locked(int ino, unsigned off, const void *buffer, unsigned len)
{
    unsigned end;
    unsigned needed;
    unsigned want;
    unsigned old_size;
    int start;
    char *dst;

    if (ino <= 0 || !ino_used[ino])
        return FS_EBAD;
    if (ino_type[ino] != FS_TYPE_FILE)
        return FS_EISDIR;
    if (len == 0)
        return 0;
    end = off + len;
    if (end < off)
        return FS_EINVAL;

    if (off > ino_size[ino]) {
        /* Filling a hole: make sure the gap reads as zero. */
        needed = (end + FS_BLOCK_SIZE - 1u) / FS_BLOCK_SIZE;
        if (needed > ino_blocks[ino]) {
            /* Fall through to the grow path below. */
        } else {
            k_memset(block_ptr(ino_start[ino]) + ino_size[ino], 0, off - ino_size[ino]);
        }
    }

    needed = (end + FS_BLOCK_SIZE - 1u) / FS_BLOCK_SIZE;
    if (needed > ino_blocks[ino]) {
        want = ino_blocks[ino] == 0 ? 1u : ino_blocks[ino];
        while (want < needed)
            want *= 2u;
        start = alloc_blocks(want);
        if (start < 0 && want != needed) {
            want = needed;
            start = alloc_blocks(want);
        }
        if (start < 0)
            return start;
        k_memset(block_ptr((unsigned)start), 0, want * FS_BLOCK_SIZE);
        old_size = ino_size[ino];
        if (old_size > off)
            old_size = off;
        if (old_size != 0)
            k_memcpy(block_ptr((unsigned)start), block_ptr(ino_start[ino]), old_size);
        if (ino_blocks[ino] != 0)
            release_blocks(ino_start[ino], ino_blocks[ino]);
        ino_start[ino] = (unsigned)start;
        ino_blocks[ino] = want;
    }

    dst = block_ptr(ino_start[ino]);
    k_memcpy(dst + off, buffer, len);
    if (end > ino_size[ino])
        ino_size[ino] = end;
    return (int)len;
}

static int read_locked(int ino, unsigned off, void *buffer, unsigned len)
{
    if (ino < 0 || ino >= (int)FS_MAX_INODES || !ino_used[ino])
        return FS_EBAD;
    if (ino_type[ino] != FS_TYPE_FILE)
        return FS_EISDIR;
    if (off >= ino_size[ino])
        return 0;
    if (len > ino_size[ino] - off)
        len = ino_size[ino] - off;
    k_memcpy(buffer, block_ptr(ino_start[ino]) + off, len);
    return (int)len;
}

static void remove_inode(int ino)
{
    if (ino_blocks[ino] != 0)
        release_blocks(ino_start[ino], ino_blocks[ino]);
    ino_used[ino] = 0;
    ino_blocks[ino] = 0;
    ino_size[ino] = 0;
    ino_start[ino] = 0;
}

void fs_lock(void)
{
    spin_lock(&fs_lock_word);
}

void fs_unlock(void)
{
    spin_unlock(&fs_lock_word);
}

int fs_init(const unsigned *count, const unsigned *entries,
            const char *names, const unsigned *data)
{
    unsigned i;
    unsigned n = *count;
    unsigned name_offset;
    unsigned type;
    unsigned size;
    unsigned data_offset;
    unsigned ino;

    for (i = 0; i < FS_MAX_INODES; ++i) {
        ino_used[i] = 0;
        ino_type[i] = FS_TYPE_FREE;
        ino_parent[i] = 0;
        ino_size[i] = 0;
        ino_start[i] = 0;
        ino_blocks[i] = 0;
        ino_name[i][0] = 0;
    }
    for (i = 0; i < FS_MAP_WORDS; ++i)
        block_map[i] = 0;
    free_block_count = FS_BLOCKS;

    ino_used[0] = 1;
    ino_type[0] = FS_TYPE_DIR;
    ino_parent[0] = 0;
    ino_name[0][0] = '/';
    ino_name[0][1] = 0;

    for (i = 0; i < n; ++i) {
        name_offset = entries[i * 4u + 0u];
        type = entries[i * 4u + 1u];
        size = entries[i * 4u + 2u];
        data_offset = entries[i * 4u + 3u];
        if (name_offset >= 0x10000u || data_offset >= FS_BYTES)
            break;
        ino = (unsigned)fs_create_path(0, names + name_offset, (int)type,
                                       (const void *)(data + data_offset / 4u), size);
        if ((int)ino < 0)
            break;
    }
    return i == n ? 0 : (int)i + 1;
}

int fs_lookup_locked(int cwd, const char *path)
{
    return lookup_locked(cwd, path);
}

int fs_lookup_path(int cwd, const char *path)
{
    int ino;
    fs_lock();
    ino = lookup_locked(cwd, path);
    fs_unlock();
    return ino;
}

int fs_open_path(int cwd, const char *path, unsigned flags)
{
    int ino;
    int mode = (int)(flags & 3u);

    fs_lock();
    ino = lookup_locked(cwd, path);
    if (ino == FS_ENOENT && (flags & FS_O_CREAT) != 0)
        ino = create_locked(cwd, path, FS_TYPE_FILE);
    if (ino >= 0) {
        if (ino_type[ino] == FS_TYPE_DIR) {
            if ((flags & (FS_O_WRONLY | FS_O_RDWR | FS_O_TRUNC)) != 0)
                ino = FS_EISDIR;
        } else if ((flags & FS_O_TRUNC) != 0 && (mode == FS_O_WRONLY || mode == FS_O_RDWR)) {
            truncate_locked(ino);
        }
    }
    fs_unlock();
    return ino;
}

int fs_create_path(int cwd, const char *path, int type,
                   const void *payload, unsigned len)
{
    int ino;
    fs_lock();
    ino = create_locked(cwd, path, type);
    if (ino >= 0 && type == FS_TYPE_FILE && len != 0)
        write_locked(ino, 0, payload, len);
    fs_unlock();
    return ino;
}

int fs_unlink_path(int cwd, const char *path)
{
    int ino;
    fs_lock();
    ino = lookup_locked(cwd, path);
    if (ino == 0)
        ino = FS_EBAD;
    else if (ino < 0)
        ;
    else if (ino_type[ino] == FS_TYPE_DIR)
        ino = FS_EISDIR;
    else
        remove_inode(ino);
    fs_unlock();
    return ino < 0 ? ino : 0;
}

int fs_rmdir_path(int cwd, const char *path)
{
    int ino;
    fs_lock();
    ino = lookup_locked(cwd, path);
    if (ino == 0)
        ino = FS_EBAD;
    else if (ino < 0)
        ;
    else if (ino_type[ino] != FS_TYPE_DIR)
        ino = FS_ENOTDIR;
    else if (!dir_is_empty((unsigned)ino))
        ino = FS_ENOTEMPTY;
    else
        remove_inode(ino);
    fs_unlock();
    return ino < 0 ? ino : 0;
}

int fs_rename_path(int cwd, const char *from, const char *to)
{
    char leaf[FS_MAX_NAME];
    int src;
    int parent;
    int cur;
    unsigned i;

    fs_lock();
    src = lookup_locked(cwd, from);
    if (src <= 0) {
        fs_unlock();
        return src < 0 ? src : FS_EBAD;
    }
    parent = resolve_parent(cwd, to, leaf, FS_MAX_NAME);
    if (parent < 0) {
        fs_unlock();
        return parent;
    }
    if (ino_type[parent] != FS_TYPE_DIR) {
        fs_unlock();
        return FS_ENOTDIR;
    }
    if (child_find((unsigned)parent, leaf, k_strlen(leaf)) >= 0) {
        fs_unlock();
        return FS_EEXIST;
    }
    if (ino_type[src] == FS_TYPE_DIR) {
        /* A directory cannot move underneath itself. */
        cur = parent;
        for (i = 0; i <= FS_MAX_INODES; ++i) {
            if (cur == src) {
                fs_unlock();
                return FS_EINVAL;
            }
            if (cur == 0)
                break;
            cur = (int)ino_parent[cur];
        }
    }
    ino_parent[src] = (unsigned)parent;
    k_strncpy(ino_name[src], leaf, FS_MAX_NAME);
    fs_unlock();
    return 0;
}

int fs_read(int ino, unsigned off, void *buffer, unsigned len)
{
    int result;
    fs_lock();
    result = read_locked(ino, off, buffer, len);
    fs_unlock();
    return result;
}

int fs_read_locked(int ino, unsigned off, void *buffer, unsigned len)
{
    return read_locked(ino, off, buffer, len);
}

int fs_write(int ino, unsigned off, const void *buffer, unsigned len)
{
    int result;
    fs_lock();
    result = write_locked(ino, off, buffer, len);
    fs_unlock();
    return result;
}

int fs_truncate(int ino)
{
    int result;
    fs_lock();
    result = truncate_locked(ino);
    fs_unlock();
    return result;
}

int fs_readdir(int ino, unsigned index, char *name, unsigned cap)
{
    unsigned i;
    unsigned seen = 0;

    fs_lock();
    if (ino < 0 || ino >= (int)FS_MAX_INODES || !ino_used[ino]) {
        fs_unlock();
        return FS_EBAD;
    }
    if (ino_type[ino] != FS_TYPE_DIR) {
        fs_unlock();
        return FS_ENOTDIR;
    }
    for (i = 1; i < FS_MAX_INODES; ++i) {
        if (!ino_used[i] || ino_parent[i] != (unsigned)ino)
            continue;
        if (seen == index) {
            k_strncpy(name, ino_name[i], cap);
            fs_unlock();
            return (int)ino_type[i];
        }
        ++seen;
    }
    fs_unlock();
    return 0;
}

int fs_stat(int ino, unsigned *info)
{
    fs_lock();
    if (ino < 0 || ino >= (int)FS_MAX_INODES || !ino_used[ino]) {
        fs_unlock();
        return FS_EBAD;
    }
    info[0] = ino_type[ino];
    info[1] = ino_type[ino] == FS_TYPE_DIR ? 0 : ino_size[ino];
    info[2] = (unsigned)ino;
    info[3] = ino_blocks[ino];
    fs_unlock();
    return 0;
}

int fs_cwd_path(int ino, char *buffer, unsigned cap)
{
    int chain[FS_MAX_CHAIN];
    unsigned depth = 0;
    unsigned used = 0;
    unsigned i;
    unsigned len;

    fs_lock();
    if (ino < 0 || ino >= (int)FS_MAX_INODES || !ino_used[ino]) {
        fs_unlock();
        return FS_EBAD;
    }
    if (ino == 0) {
        if (cap < 2) {
            fs_unlock();
            return FS_EINVAL;
        }
        buffer[0] = '/';
        buffer[1] = 0;
        fs_unlock();
        return 0;
    }
    while (ino != 0) {
        if (depth == FS_MAX_CHAIN) {
            fs_unlock();
            return FS_EINVAL;
        }
        chain[depth++] = ino;
        ino = (int)ino_parent[ino];
    }
    while (depth != 0) {
        --depth;
        len = k_strlen(ino_name[chain[depth]]);
        if (used + 1u + len + 1u > cap) {
            fs_unlock();
            return FS_EINVAL;
        }
        buffer[used++] = '/';
        k_strncpy(buffer + used, ino_name[chain[depth]], cap - used);
        used += len;
    }
    buffer[used] = 0;
    fs_unlock();
    return 0;
}

int fs_name(int ino, char *buffer, unsigned cap)
{
    if (ino < 0 || ino >= (int)FS_MAX_INODES || !ino_used[ino])
        return FS_EBAD;
    k_strncpy(buffer, ino_name[ino], cap);
    return 0;
}

int fs_type(int ino)
{
    if (ino < 0 || ino >= (int)FS_MAX_INODES || !ino_used[ino])
        return FS_EBAD;
    return (int)ino_type[ino];
}

int fs_type_locked(int ino)
{
    if (ino < 0 || ino >= (int)FS_MAX_INODES || !ino_used[ino])
        return FS_EBAD;
    return (int)ino_type[ino];
}

int fs_size(int ino)
{
    if (ino < 0 || ino >= (int)FS_MAX_INODES || !ino_used[ino])
        return FS_EBAD;
    return (int)ino_size[ino];
}

int fs_size_locked(int ino)
{
    if (ino < 0 || ino >= (int)FS_MAX_INODES || !ino_used[ino])
        return FS_EBAD;
    return (int)ino_size[ino];
}

unsigned fs_total_blocks(void)
{
    return FS_BLOCKS;
}

unsigned fs_free_blocks(void)
{
    return free_block_count;
}

unsigned fs_total_inodes(void)
{
    return FS_MAX_INODES;
}

unsigned fs_free_inodes(void)
{
    unsigned i;
    unsigned n = 0;
    for (i = 1; i < FS_MAX_INODES; ++i) {
        if (!ino_used[i])
            ++n;
    }
    return n;
}
