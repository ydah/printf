extern int printf(const char *, ...);

int main(void) {
  return printf("%c", 66) == 1 ? 0 : 1;
}
