extern int putchar(int);

__attribute__((noinline)) static unsigned char pick(void) {
  return 66;
}

int main(void) {
  return putchar((int)pick()) == 66 ? 0 : 1;
}
