int value = 0x12345678;
int zero;
char message[] = "roco";

int add(int a, int b) { return a + b; }

int sum(int *p, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) {
    s += p[i];
  }
  return s;
}

int main(void) {
  int a[4];
  for (int i = 0; i < 4; i++) {
    a[i] = i + 1;
  }
  if (add(value & 0xff, 0) != 0x78) return 3;
  if (sum(a, 4) != 10) return 4;
  if (message[0] != 'r') return 5;
  if (zero != 0) return 6;
  return 0;
}
