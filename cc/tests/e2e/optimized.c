// Optimized C workload for roco_cc -O2.
//
// The helper functions use constant multipliers, signed and unsigned
// power-of-two division/remainder, negative divisors, and one non-power-of-two
// division that must fall back to the hardware divider. The expected values
// are explicit so the test covers the generated shift/add sequences rather
// than reusing the same transformation for the reference.

int mul3(int x) { return x * 3; }
int mul5(int x) { return x * 5; }
int mul7(int x) { return x * 7; }
int mul10(int x) { return x * 10; }
int mul11(int x) { return x * 11; }
int mul13(int x) { return x * 13; }
int mul15(int x) { return x * 15; }
int mul17(int x) { return x * 17; }
int mul38(int x) { return x * 38; }

int div4(int x) { return x / 4; }
int mod4(int x) { return x % 4; }
int divm4(int x) { return x / -4; }
int modm4(int x) { return x % -4; }
int div8(int x) { return x / 8; }
int mod8(int x) { return x % 8; }
unsigned int udiv8(unsigned int x) { return x / 8u; }
unsigned int umod8(unsigned int x) { return x % 8u; }
int div3(int x) { return x / 3; }
int mod3(int x) { return x % 3; }

int add5(int x) {
  x += 5;
  return x;
}
int times3(int x) {
  x *= 3;
  return x;
}
int quarter(int x) {
  x /= 4;
  return x;
}
int rem4(int x) {
  x %= 4;
  return x;
}
int advance(int *p) {
  p += 2;
  return *p;
}
int add_through(int *p) {
  *p += 5;
  return *p;
}

static int check_multipliers(int x) {
  int failures = 0;
  failures += mul3(x) != x * 3;
  failures += mul5(x) != x * 5;
  failures += mul7(x) != x * 7;
  failures += mul10(x) != x * 10;
  failures += mul11(x) != x * 11;
  failures += mul13(x) != x * 13;
  failures += mul15(x) != x * 15;
  failures += mul17(x) != x * 17;
  failures += mul38(x) != x * 38;
  return failures;
}

int main(void) {
  int values[7];
  values[0] = 0;
  values[1] = 1;
  values[2] = -1;
  values[3] = 7;
  values[4] = -9;
  values[5] = 123456;
  values[6] = -123456;
  for (int i = 0; i < 7; i++) {
    if (check_multipliers(values[i]) != 0) {
      return 10 + i;
    }
  }

  if (mul11(7) != 77) return 30;
  if (mul11(-9) != -99) return 31;
  if (mul38(-9) != -342) return 32;
  if (div4(-9) != -2) return 33;
  if (mod4(-9) != -1) return 34;
  if (div4(9) != 2) return 35;
  if (mod4(9) != 1) return 36;
  if (div4(-1) != 0) return 37;
  if (mod4(-1) != -1) return 38;
  if (divm4(-9) != 2) return 39;
  if (modm4(-9) != -1) return 40;
  if (divm4(9) != -2) return 41;
  if (modm4(9) != 1) return 42;
  if (div8(-9) != -1) return 43;
  if (mod8(-9) != -1) return 44;
  if (udiv8(0xffffffffu) != 0x1fffffffu) return 45;
  if (umod8(0xffffffffu) != 7u) return 46;
  if (div3(-10) != -3) return 47;
  if (mod3(-10) != -1) return 48;
  if (div4(-2147483647 - 1) != -536870912) return 49;
  if (mod4(-2147483647 - 1) != 0) return 50;
  if (add5(7) != 12) return 51;
  if (times3(-7) != -21) return 52;
  if (quarter(-9) != -2) return 53;
  if (rem4(-9) != -1) return 54;

  int array[4];
  array[0] = 10;
  array[1] = 20;
  array[2] = 30;
  array[3] = 40;
  if (advance(array) != 30) return 55;
  if (add_through(array) != 15) return 56;
  return 0;
}
