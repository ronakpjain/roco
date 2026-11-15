// C workload for the vector-oriented testbench.
//
// The two kernels below are ordinary C loops with no vector intrinsics.
// roco-cc currently emits scalar RV32IMA, so this checks the C ABI,
// memory, and arithmetic paths rather than vector code generation.
//
// The drivers fill the arrays through volatile pointers so that the
// compiler cannot fold the loops into vector constants.

#include <stdint.h>

static int32_t a[64];
static int32_t b[64];
static int32_t o[64];
static volatile unsigned g_n = 64;

__attribute__((noinline)) static void add_arrays(int32_t *restrict d, const int32_t *restrict x,
                                                 const int32_t *restrict y, unsigned n) {
  for (unsigned i = 0; i < n; i++) {
    d[i] = x[i] + y[i];
  }
}

__attribute__((noinline)) static int32_t sum_array(const int32_t *restrict x, unsigned n) {
  int32_t s = 0;
  for (unsigned i = 0; i < n; i++) {
    s += x[i];
  }
  return s;
}

int main(void) {
  int32_t seed = (int32_t) * (volatile uint32_t *)0x80000014;
  for (int i = 0; i < 64; i++) {
    ((volatile int32_t *)a)[i] = i + seed;
    ((volatile int32_t *)b)[i] = 2 * i;
  }

  add_arrays(o, a, b, g_n);
  int32_t total = sum_array(a, g_n);

  int ok = 1;
  for (int i = 0; i < 64; i++) {
    if (((volatile int32_t *)o)[i] != 3 * i + seed) {
      ok = 0;
    }
  }
  if (total != (63 * 64 / 2) + 64 * seed) {
    ok = 0;
  }
  if (!ok) {
    *(volatile uint32_t *)0x80001000 = 3u;
  }
  return ok ? 0 : 1;
}
