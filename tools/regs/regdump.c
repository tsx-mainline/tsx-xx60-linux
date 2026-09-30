/*
 * regdump: read (and optionally write) Meson8 CBUS/VCBUS/AOBUS registers
 * through /dev/mem. Output format matches captures/tsw-1060/regs-live.txt.
 *   regdump c|v|a FIRST [LAST]      read register(s) (register index, not byte addr)
 *   regdump -w c|v|a REG VALUE      write one register (used only for the
 *                                   cts_encl gate toggle test)
 * c = CBUS 0xc1100000, v = VCBUS 0xd0100000, a = AOBUS 0xc8100000. Addr = base + reg*4
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

static unsigned long base_of(char c, const char **name)
{
	switch (c) {
	case 'c': *name = "CBUS"; return 0xc1100000UL;
	case 'v': *name = "VCBUS"; return 0xd0100000UL;
	case 'a': *name = "AOBUS"; return 0xc8100000UL;
	}
	fprintf(stderr, "bus must be c, v or a\n");
	exit(2);
}

int main(int argc, char **argv)
{
	int wr = argc > 1 && !strcmp(argv[1], "-w");
	const char *name;
	if (argc < 3 + wr) {
		fprintf(stderr, "usage: regdump c|v|a FIRST [LAST] | regdump -w c|v|a REG VAL\n");
		return 2;
	}
	unsigned long base = base_of(argv[1 + wr][0], &name);
	unsigned long first = strtoul(argv[2 + wr], NULL, 0);
	unsigned long last = (!wr && argc > 3) ? strtoul(argv[3], NULL, 0) : first;
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) { perror("/dev/mem"); return 1; }
	unsigned long start = (base + first * 4) & ~0xfffUL;
	size_t len = ((base + last * 4 + 4 - start) + 0xfff) & ~0xfffUL;
	volatile uint32_t *m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, start);
	if (m == MAP_FAILED) { perror("mmap"); return 1; }
	for (unsigned long r = first; r <= last; r++) {
		volatile uint32_t *p = m + ((base + r * 4 - start) / 4);
		if (wr) {
			uint32_t v = strtoul(argv[4], NULL, 0);
			uint32_t old = *p;
			*p = v;
			printf("%s[0x%04lx]=0x%08x -> 0x%08x (read back 0x%08x)\n", name, r, old, v, *p);
		} else {
			printf("%s[0x%04lx]=0x%08x\n", name, r, *p);
		}
	}
	return 0;
}
