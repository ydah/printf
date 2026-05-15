extern int putchar(int);

int main(void) {
  int total = 0;
  for (int i = 0; i < 3; i++) {
    total += i;
  }
  if (total == 3) {
    return putchar(66) == 66 ? 0 : 1;
  }
  return putchar(78) == 78 ? 1 : 2;
}
