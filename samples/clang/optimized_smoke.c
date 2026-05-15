extern int putchar(int);

int main(void) {
  unsigned char bytes[2] = {65, 66};
  unsigned int value = bytes[1];
  return putchar((int)value) == 66 ? 0 : 1;
}
