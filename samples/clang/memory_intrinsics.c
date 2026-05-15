extern int putchar(int);

int main(void) {
  unsigned char source[4] = {65, 66, 0, 0};
  unsigned char target[4];
  __builtin_memset(target, 0, sizeof(target));
  __builtin_memcpy(target, source, 2);
  return putchar((int)target[1]) == 66 ? 0 : 1;
}
