/* rvvm environment for riscv-tests (docs/REQ_RVVM.md section 6): no privilege
   model; pass and fail leave through ECALL exit (a7 = 93), a0 = 0 or the
   failing test number. */
#ifndef _RVVM_RISCV_TEST_H
#define _RVVM_RISCV_TEST_H

#define RVTEST_RV32U  .option norvc;
#define RVTEST_RV64U  RVTEST_RV32U

#define TESTNUM gp

#define RVTEST_CODE_BEGIN        \
        .section .text.init;     \
        .align 2;                \
        .globl _start;           \
_start: li TESTNUM, 0;

#define RVTEST_CODE_END  unimp

/* pass: exit(0); fail: exit(TESTNUM), TESTNUM is never 0 at a failure */
#define RVTEST_PASS      \
        li a0, 0;        \
        li a7, 93;       \
        ecall;

#define RVTEST_FAIL      \
        mv a0, TESTNUM;  \
        li a7, 93;       \
        ecall;

#define RVTEST_DATA_BEGIN  .data; .align 4;
#define RVTEST_DATA_END

#endif
