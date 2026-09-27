/* Ordinary numeric C in double and single: series, Newton's square root, a
   small linear solve, a polynomial by Horner - the code a compiler makes from
   plain arithmetic.  Exits 0 when the answers are what the host computed. */
#include "rvvm.h"

static double newton_sqrt(double v) {
    double x = v > 1 ? v : 1;
    for (int i = 0; i < 60; i++) x = 0.5 * (x + v / x);
    return x;
}

int main(void) {
    /* pi by Leibniz, 2000 terms, in double and single */
    double pd = 0; float pf = 0;
    for (int k = 0; k < 2000; k++) {
        double t = (k & 1 ? -4.0 : 4.0) / (2 * k + 1);
        pd += t; pf += (float)t;
    }
    /* e by its series */
    double e = 1, term = 1;
    for (int k = 1; k < 20; k++) { term /= k; e += term; }
    /* 3x3 Gaussian elimination */
    double m[3][4] = {{2, 1, -1, 8}, {-3, -1, 2, -11}, {-2, 1, 2, -3}};
    for (int c = 0; c < 3; c++)
        for (int r = c + 1; r < 3; r++) {
            double f = m[r][c] / m[c][c];
            for (int k = c; k < 4; k++) m[r][k] -= f * m[c][k];
        }
    double x2 = m[2][3] / m[2][2];
    double x1 = (m[1][3] - m[1][2] * x2) / m[1][1];
    double x0 = (m[0][3] - m[0][2] * x2 - m[0][1] * x1) / m[0][0];
    /* Horner */
    const double cf[6] = {1.5, -2.25, 0.125, 3.0, -0.5, 0.0625};
    double h = 0;
    for (int i = 0; i < 6; i++) h = h * 1.75 + cf[i];
    double s2 = newton_sqrt(2.0);

    int ok = 1;
    ok &= pd > 3.1410 && pd < 3.1422;
    ok &= pf > 3.140f && pf < 3.143f;
    ok &= e > 2.718281828 && e < 2.718281829;
    ok &= x0 > 1.999999 && x0 < 2.000001 && x1 > 2.999999 && x1 < 3.000001 && x2 > -1.000001 && x2 < -0.999999;
    ok &= h > 12.56 && h < 12.57;
    ok &= s2 * s2 > 1.9999999999 && s2 * s2 < 2.0000000001;
    ok &= (int)(pd * 1000) == 3141;
    rvvm_write(1, ok ? "fp_numeric ok\n" : "fp_numeric WRONG\n", ok ? 14 : 17);
    return ok ? 0 : 1;
}
