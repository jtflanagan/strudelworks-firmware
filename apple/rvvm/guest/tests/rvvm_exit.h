/* rvvm's own edge tests (sim/run_rvvm_tests.sh): pass = exit(0), fail = exit(gp). */
        .option norvc
#define PASS  li a0, 0; li a7, 93; ecall
#define FAIL  mv a0, gp; li a7, 93; ecall
