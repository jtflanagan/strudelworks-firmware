/* rvgs_posix.c - picolibc's system calls for a GS/OS application's program
   (docs/RVV2_DOOM.md): what tinystdio's fopen/fread/fseek and malloc sit on,
   over librvgs.  Files are GS/OS's, read-only, through the bounce buffer (a
   descriptor is the GS/OS refNum + 3) - but /tmp/, which is the program's own
   memory (a descriptor TMP_FD + a slot: DOOM's music writes its MIDI there
   and reads it back); the console is discarded (a desktop
   application has none); the heap grows from the image's end toward the stack
   in the application's upper-half memory; _exit is the runtime's exit. */
#include <stdint.h>
#include <errno.h>
#include <stddef.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include "rvgs.h"

#define FD_BASE 3

/* /tmp/: files in the heap, gone when the program ends. */
#define TMP_FD    1000
#define TMP_FILES 4
static struct tmpf { char name[32]; uint8_t *data; size_t len, cap; int used; } tmp[TMP_FILES];
static struct { int file; size_t pos; int open; } tmp_fd[TMP_FILES];

static int is_tmp(const char *p) { return strncmp(p, "/tmp/", 5) == 0; }

static int tmp_find(const char *name) {
    for (int i = 0; i < TMP_FILES; i++) if (tmp[i].used && strcmp(tmp[i].name, name) == 0) return i;
    return -1;
}

static int tmp_open(const char *path, int flags) {
    int f = tmp_find(path);
    if (f < 0) {
        if (!(flags & O_CREAT)) { errno = ENOENT; return -1; }
        for (f = 0; f < TMP_FILES && tmp[f].used; f++) {}
        if (f == TMP_FILES || strlen(path) >= sizeof tmp[f].name) { errno = ENOSPC; return -1; }
        strcpy(tmp[f].name, path);
        tmp[f].used = 1; tmp[f].data = NULL; tmp[f].len = tmp[f].cap = 0;
    } else if (flags & O_TRUNC) tmp[f].len = 0;
    for (int d = 0; d < TMP_FILES; d++)
        if (!tmp_fd[d].open) {
            tmp_fd[d].open = 1; tmp_fd[d].file = f;
            tmp_fd[d].pos = (flags & O_APPEND) ? tmp[f].len : 0;
            return TMP_FD + d;
        }
    errno = EMFILE;
    return -1;
}


/* The console: a line at a time to ECALL write - which the runtime discards
   (a desktop application has no console) and the bench shows. */
static char line[120];
static unsigned line_n;
static void line_out(void) {
    register long a0 __asm__("a0") = 1;
    register long a1 __asm__("a1") = (long)(uintptr_t)line;
    register long a2 __asm__("a2") = (long)line_n;
    register long a7 __asm__("a7") = 64;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
    line_n = 0;
}
static int con_putc(char c, FILE *f) {
    (void)f;
    line[line_n++] = c;
    if (c == '\n' || line_n == sizeof line) line_out();
    return (unsigned char)c;
}
static int no_getc(FILE *f) { (void)f; return EOF; }
static FILE console = FDEV_SETUP_STREAM(con_putc, no_getc, NULL, _FDEV_SETUP_RW);
FILE *const stdin = &console;
__strong_reference(stdin, stdout);
__strong_reference(stdin, stderr);

static int gs_err(long e) {
    switch (-e) {
    case 0x46: case 0x45: case 0x44: return ENOENT;       /* file, volume, path not found */
    case 0x4E: case 0x2B: return EACCES;                  /* access, write-protected */
    default: return EIO;
    }
}

int open(const char *path, int flags, ...) {
    if (is_tmp(path)) return tmp_open(path, flags);
    if ((flags & O_ACCMODE) != O_RDONLY) { errno = EROFS; return -1; }
    const int ref = rvgs_open(path);
    if (ref < 0) { errno = gs_err(ref); return -1; }
    return ref + FD_BASE;
}

ssize_t read(int fd, void *buf, size_t n) {
    if (fd >= TMP_FD && fd < TMP_FD + TMP_FILES && tmp_fd[fd - TMP_FD].open) {
        struct tmpf *t = &tmp[tmp_fd[fd - TMP_FD].file];
        size_t *pos = &tmp_fd[fd - TMP_FD].pos;
        if (*pos >= t->len) return 0;
        if (n > t->len - *pos) n = t->len - *pos;
        memcpy(buf, t->data + *pos, n);
        *pos += n;
        return (ssize_t)n;
    }
    if (fd < FD_BASE) return 0;
    const long r = rvgs_read(fd - FD_BASE, buf, n);
    if (r < 0) { errno = gs_err(r); return -1; }
    return r;
}

ssize_t write(int fd, const void *buf, size_t n) {
    if (fd >= TMP_FD && fd < TMP_FD + TMP_FILES && tmp_fd[fd - TMP_FD].open) {
        struct tmpf *t = &tmp[tmp_fd[fd - TMP_FD].file];
        size_t *pos = &tmp_fd[fd - TMP_FD].pos;
        if (*pos + n > t->cap) {
            size_t cap = t->cap ? t->cap : 4096;
            while (cap < *pos + n) cap *= 2;
            uint8_t *d = realloc(t->data, cap);
            if (!d) { errno = ENOSPC; return -1; }
            t->data = d; t->cap = cap;
        }
        if (*pos > t->len) memset(t->data + t->len, 0, *pos - t->len);
        memcpy(t->data + *pos, buf, n);
        *pos += n;
        if (*pos > t->len) t->len = *pos;
        return (ssize_t)n;
    }
    if (fd == 1 || fd == 2) return (ssize_t)n;          /* the console: discarded */
    errno = EBADF;
    return -1;
}

off_t lseek(int fd, off_t off, int whence) {
    if (fd >= TMP_FD && fd < TMP_FD + TMP_FILES && tmp_fd[fd - TMP_FD].open) {
        const long base = whence == SEEK_CUR ? (long)tmp_fd[fd - TMP_FD].pos
                        : whence == SEEK_END ? (long)tmp[tmp_fd[fd - TMP_FD].file].len : 0;
        if (base + (long)off < 0) { errno = EINVAL; return -1; }
        tmp_fd[fd - TMP_FD].pos = (size_t)(base + (long)off);
        return (off_t)tmp_fd[fd - TMP_FD].pos;
    }
    if (fd < FD_BASE) { errno = ESPIPE; return -1; }
    const int ref = fd - FD_BASE;
    long base = 0;
    if (whence == SEEK_CUR) base = rvgs_tell(ref);
    else if (whence == SEEK_END) base = rvgs_eof(ref);
    if (base < 0) { errno = gs_err(base); return -1; }
    const long pos = base + (long)off;
    if (pos < 0) { errno = EINVAL; return -1; }
    const long r = rvgs_seek(ref, (unsigned long)pos);
    if (r < 0) { errno = gs_err(r); return -1; }
    return pos;
}

int close(int fd) {
    if (fd >= TMP_FD && fd < TMP_FD + TMP_FILES) { tmp_fd[fd - TMP_FD].open = 0; return 0; }
    if (fd < FD_BASE) return 0;
    const int r = rvgs_close(fd - FD_BASE);
    if (r < 0) { errno = gs_err(r); return -1; }
    return 0;
}

/* The heap: from the image's end (rv_env->heap_base) to the stack's bottom -
   the stack's size read from the program's own image header (crt0_app.S, +16). */
void *sbrk(ptrdiff_t incr) {
    static uintptr_t brk;
    if (!brk) brk = (rv_env->heap_base + 15) & ~(uintptr_t)15;
    const uint32_t stack = *(const uint32_t *)(uintptr_t)(rv_env->image_base + 16);
    const uintptr_t limit = rv_env->hi_base + rv_env->hi_size - stack;
    const uintptr_t old = brk;
    if ((incr > 0 && brk + (uintptr_t)incr > limit) || (incr < 0 && (uintptr_t)(-incr) > brk - rv_env->heap_base)) {
        errno = ENOMEM;
        return (void *)-1;
    }
    brk += (uintptr_t)incr;
    return (void *)old;
}

void _exit(int code) {
    if (line_n) line_out();                    /* the last line, even unended */
    rvgs_exit(code);
}

/* Nothing written but /tmp/ (saves and the config fail as on a read-only
   disk), and no processes (picolibc's system()). */
int rename(const char *from, const char *to) { (void)from; (void)to; errno = EROFS; return -1; }
int mkdir(const char *path, mode_t mode) { (void)path; (void)mode; errno = EROFS; return -1; }
int unlink(const char *path) {
    if (is_tmp(path)) {
        const int f = tmp_find(path);
        if (f < 0) { errno = ENOENT; return -1; }
        free(tmp[f].data);
        tmp[f].used = 0; tmp[f].data = NULL;
        return 0;
    }
    errno = EROFS;
    return -1;
}
pid_t fork(void) { errno = ENOSYS; return -1; }
pid_t waitpid(pid_t pid, int *status, int options) { (void)pid; (void)status; (void)options; errno = ENOSYS; return -1; }
int execve(const char *path, char *const argv[], char *const envp[]) { (void)path; (void)argv; (void)envp; errno = ENOSYS; return -1; }
