/* picolibc's console on rvvm: stdin/stdout/stderr through the VM's ECALL
   read and write, one character at a time (tinystdio's FDEV streams). */
#include <stdio.h>
#include "rvvm.h"

static int rvvm_putc(char c, FILE *f) {
    (void)f;
    rvvm_write(1, &c, 1);
    return (unsigned char)c;
}

static int rvvm_getc(FILE *f) {
    (void)f;
    unsigned char c;
    return rvvm_read(0, &c, 1) == 1 ? c : EOF;
}

static FILE rvvm_stdio = FDEV_SETUP_STREAM(rvvm_putc, rvvm_getc, NULL, _FDEV_SETUP_RW);

FILE *const stdin = &rvvm_stdio;
__strong_reference(stdin, stdout);
__strong_reference(stdin, stderr);

void _exit(int code) {
    rvvm_exit(code);
}
