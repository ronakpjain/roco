unsigned int u = 0xffffffffu;
int neg = -5;
char c = -1;
unsigned char uc = 255;
short s = -2;
int global_array[4] = {10, 20, 30, 40};

int fact(int n) {
  if (n <= 1) return 1;
  return n * fact(n - 1);
}

int sum_array(int *p, int n) {
  int total = 0;
  for (int i = 0; i < n; i++) total += p[i];
  return total;
}

static char names[4][8];
static unsigned counts[3][4];

int row_sum(char *p) {
  int total = 0;
  int k;
  for (k = 0; k < 8; k++) total += p[k];
  return total;
}

int main(void) {
  if (sizeof(int) != 4) return 10;
  if (sizeof(short) != 2) return 11;
  if (neg != -5) return 12;
  if (c != -1) return 13;
  if (uc != 255) return 14;
  if (s != -2) return 15;
  if (u / 2 != 0x7fffffffu) return 16;
  if ((u >> 1) != 0x7fffffffu) return 17;
  if (~0 != -1) return 18;
  if (!0 != 1) return 19;

  int *p = global_array;
  if (*p != 10) return 20;
  p++;
  if (*p != 20) return 21;
  p = p + 1;
  if (*p != 30) return 22;
  p--;
  if (*p != 20) return 23;
  int *q = global_array + 3;
  if (q - p != 2) return 24;

  int total = 0;
  for (int i = 0; i < 6; i++) {
    if (i == 1) continue;
    if (i == 5) break;
    total += i;
  }
  if (total != 0 + 2 + 3 + 4) return 25;

  int d = 0;
  do {
    d++;
  } while (d < 3);
  if (d != 3) return 26;

  int x = 1;
  int y = +x;
  int z = x++;
  int w = ++x;
  if (y != 1 || z != 1 || w != 3 || x != 3) return 27;

  if (sum_array(global_array, 4) != 100) return 28;
  if (fact(5) != 120) return 29;

  unsigned i;
  unsigned j;
  for (i = 0; i < 4u; i++) {
    for (j = 0; j < 8u; j++) {
      names[i][j] = (char)(i * 8u + j);
    }
  }
  for (i = 0; i < 3u; i++) {
    for (j = 0; j < 4u; j++) {
      counts[i][j] = i * 100u + j;
    }
  }
  if (names[0][0] != 0) return 40;
  if (names[3][7] != 31) return 41;
  if (counts[0][0] != 0) return 42;
  if (counts[2][3] != 203) return 43;
  if (names[2] != &names[2][0]) return 44;
  if (row_sum(names[1]) != 92) return 45;
  if (names[1] + 8 != names[2]) return 46;
  return 0;
}
