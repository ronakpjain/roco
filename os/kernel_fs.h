#ifndef KERNEL_FS_H
#define KERNEL_FS_H

/*
 * A small in-memory filesystem. Files are made of contiguous 512-byte
 * blocks; inodes, names, and the block bitmap live in kernel BSS while
 * the data arena lives at a fixed physical address in SDRAM.
 */

#define FS_TYPE_FREE 0
#define FS_TYPE_FILE 1
#define FS_TYPE_DIR 2

#define FS_EBAD (-1)
#define FS_ENOENT (-2)
#define FS_ENOTDIR (-3)
#define FS_EEXIST (-4)
#define FS_ENOSPC (-5)
#define FS_EINVAL (-6)
#define FS_ENOTEMPTY (-7)
#define FS_EISDIR (-8)
#define FS_EROFS (-9)

#define FS_MAX_NAME 24u
#define FS_MAX_PATH 96u
#define FS_BLOCK_SIZE 512u

#ifndef FS_OPEN_FLAGS
#define FS_OPEN_FLAGS
#define FS_O_RDONLY 0x0u
#define FS_O_WRONLY 0x1u
#define FS_O_RDWR 0x2u
#define FS_O_CREAT 0x40u
#define FS_O_TRUNC 0x80u
#define FS_O_APPEND 0x100u
#endif

int fs_init(const unsigned *count, const unsigned *entries,
            const char *names, const unsigned *data);
int fs_lookup_path(int cwd, const char *path);
int fs_open_path(int cwd, const char *path, unsigned flags);
int fs_create_path(int cwd, const char *path, int type,
                   const void *data, unsigned len);
int fs_unlink_path(int cwd, const char *path);
int fs_rmdir_path(int cwd, const char *path);
int fs_rename_path(int cwd, const char *from, const char *to);
int fs_read(int ino, unsigned off, void *buffer, unsigned len);
int fs_write(int ino, unsigned off, const void *buffer, unsigned len);
int fs_readdir(int ino, unsigned index, char *name, unsigned cap);
int fs_stat(int ino, unsigned *info);
int fs_cwd_path(int ino, char *buffer, unsigned cap);
int fs_name(int ino, char *buffer, unsigned cap);
int fs_type(int ino);
int fs_size(int ino);
int fs_truncate(int ino);

/* Compound operations for the kernel loader and syscall layer. */
void fs_lock(void);
void fs_unlock(void);
int fs_lookup_locked(int cwd, const char *path);
int fs_read_locked(int ino, unsigned off, void *buffer, unsigned len);
int fs_type_locked(int ino);
int fs_size_locked(int ino);

unsigned fs_total_blocks(void);
unsigned fs_free_blocks(void);
unsigned fs_total_inodes(void);
unsigned fs_free_inodes(void);

#endif
