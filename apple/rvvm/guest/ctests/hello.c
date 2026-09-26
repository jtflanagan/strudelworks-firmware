/* The first C guest: a string through write(), a little arithmetic that
   needs M and Zbb, and an exit code the harness checks. */
#include "rvvm.h"

static unsigned len(const char *s) { unsigned n = 0; while (s[n]) n++; return n; }

static void put(const char *s) { rvvm_write(1, s, len(s)); }

static void putu(unsigned v) {
    char b[12]; int i = 11; b[i] = 0;
    do { b[--i] = '0' + v % 10; v /= 10; } while (v);
    put(&b[i]);
}

int main(void) {
    put("hello from RISC-V on the 65816\n");
    unsigned f = 1;
    for (unsigned i = 1; i <= 12; i++) f *= i;
    put("12! = "); putu(f); put("\n");
    return f == 479001600u ? 0 : 1;
}
