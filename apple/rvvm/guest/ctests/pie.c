/* rvvm's C tests (sim/run_rvvm_tests.sh): a static PIE that relocated itself
   (apple/rvvm/guest/crt0.S) - absolute pointers in data (strings, functions,
   a linked list), checked where they were loaded.  Exit 0 = pass.
   rvvm-hi: no I/O, so it also runs in the upper 16 MB. */
#include "rvvm.h"

static const char *names[] = {"alpha", "beta", "gamma"};
static int add(int a, int b) { return a + b; }
static int sub(int a, int b) { return a - b; }
static int (*const ops[])(int, int) = {add, sub};
struct node { struct node *next; int v; };
static struct node n2 = {0, 2};
static struct node n1 = {&n2, 1};

int main(void) {
    if (names[1][0] != 'b' || names[2][4] != 'a') return 1;
    if (ops[0](5, 3) != 8 || ops[1](5, 3) != 2) return 2;
    if (n1.next != &n2 || n1.next->v != 2) return 3;
    if ((unsigned long)&main >> 25) return 4;         /* inside the engine's 32 MB */
    /* the pointers point into this image, wherever it is */
    if ((unsigned long)names[0] < (unsigned long)&main) return 5;
    return 0;
}
