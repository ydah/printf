extern int putchar(int);

int main(void) {
  unsigned char bytes[2] = {65, 66};
  unsigned char *alias = &bytes[1];
  return putchar((int)*alias) == 66 ? 0 : 1;
}
