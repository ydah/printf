extern int putchar(int);

struct pair {
  unsigned char first;
  unsigned char second;
};

int main(void) {
  struct pair pairs[1] = {{65, 66}};
  return putchar((int)pairs[0].second) == 66 ? 0 : 1;
}
