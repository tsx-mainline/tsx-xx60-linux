/*
 * tsx-splash: the xx60 boot splash on the Linux framebuffer (/dev/fb0).
 *
 * The kernel command line maps the framebuffer console to a framebuffer
 * that never exists (fbcon=map:1), so no kernel text reaches the LCD and
 * nothing else draws on fb0: this tool owns the screen from the initramfs
 * until the kiosk's compositor takes the display (docs/boot.md "Boot
 * splash").
 *
 *   tsx-splash [-s TEXT] [-p PCT] show      image + status line + progress bar
 *   tsx-splash [-s TEXT] [-p PCT] status    redraw only the status band
 *   tsx-splash [-s TEXT] [-p PCT] png FILE  the same frame as an (uncompressed)
 *                                           PNG at the framebuffer size, for
 *                                           the compositor's background
 *   tsx-splash console                      give the screen to the text console
 *                                           (bind fbcon to fb0: boot failures,
 *                                           the rescue, BOOT_VERBOSE)
 *   tsx-splash size                         print WIDTHxHEIGHT
 *
 * Options: -d DIR (default /usr/share/tsx/splash): splash-WxH.ppm (binary
 * PPM, one per panel size; another size is centred on black) and
 * font-16.psf / font-24.psf (PSF1 or PSF2 console fonts, 24 on screens at
 * least 720 lines high); -f FB (default /dev/fb0); -p -1 = no bar;
 * -g WxH: frame size for "png" and "size" without opening the framebuffer.
 * The background of the artwork is black; the status band is redrawn on
 * black, so "status" needs no image. "show" and "status" do nothing while the
 * text console owns the screen (fbcon bound: the rescue, BOOT_VERBOSE, an
 * older kernel without fbcon=map:1), so they never draw over boot text.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/ioctl.h>
#include <unistd.h>

static const char *dir = "/usr/share/tsx/splash", *fbdev = "/dev/fb0";
static int W, H;            /* frame size */
static uint8_t *rgb;        /* frame, 3 bytes per pixel */

struct font { int w, h, n, stride; const uint8_t *g; uint8_t *mem; };

static void die(const char *m)
{
	fprintf(stderr, "tsx-splash: %s: %s\n", m, strerror(errno));
	exit(1);
}

static uint8_t *slurp(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	uint8_t *b = NULL;
	size_t n = 0, cap = 0, r;
	if (!f) return NULL;
	for (;;) {
		if (n == cap && !(b = realloc(b, cap = cap ? cap * 2 : 65536))) { fclose(f); return NULL; }
		if (!(r = fread(b + n, 1, cap - n, f))) break;
		n += r;
	}
	fclose(f);
	*len = n;
	return b;
}

static int font_load(struct font *ft, const char *path)
{
	size_t len;
	uint8_t *b = slurp(path, &len);
	memset(ft, 0, sizeof *ft);
	if (!b) return -1;
	ft->mem = b;
	if (len > 32 && b[0] == 0x72 && b[1] == 0xb5 && b[2] == 0x4a && b[3] == 0x86) {   /* PSF2 */
		uint32_t *h = (uint32_t *)b;
		ft->n = h[4]; ft->h = h[6]; ft->w = h[7]; ft->stride = (ft->w + 7) / 8;
		if (h[2] + (size_t)ft->n * h[5] > len || h[5] != (uint32_t)(ft->stride * ft->h)) return -1;
		ft->g = b + h[2];
	} else if (len > 4 && b[0] == 0x36 && b[1] == 0x04) {                             /* PSF1 */
		ft->n = (b[2] & 1) ? 512 : 256; ft->h = b[3]; ft->w = 8; ft->stride = 1;
		if (4 + (size_t)ft->n * ft->h > len) return -1;
		ft->g = b + 4;
	} else
		return -1;
	return 0;
}

static void put(int x, int y, uint32_t c)
{
	if (x < 0 || y < 0 || x >= W || y >= H) return;
	uint8_t *p = rgb + ((size_t)y * W + x) * 3;
	p[0] = c >> 16; p[1] = c >> 8; p[2] = c;
}

static void fill(int x, int y, int w, int h, uint32_t c)
{
	for (int j = y; j < y + h; j++)
		for (int i = x; i < x + w; i++)
			put(i, j, c);
}

/* text centred on (cx, y top); ASCII only (Terminus' ISO 8859-1 fonts map it 1:1) */
static void text(const struct font *ft, const char *s, int cx, int y, uint32_t c)
{
	int n = strlen(s), x = cx - n * ft->w / 2;
	for (; *s; s++, x += ft->w) {
		unsigned ch = (unsigned char)*s;
		if (ch >= (unsigned)ft->n) ch = '?';
		const uint8_t *g = ft->g + (size_t)ch * ft->stride * ft->h;
		for (int j = 0; j < ft->h; j++)
			for (int i = 0; i < ft->w; i++)
				if (g[j * ft->stride + i / 8] & (0x80 >> (i % 8)))
					put(x + i, y + j, c);
	}
}

/* binary PPM (P6, maxval 255) centred into the frame */
static int ppm_blit(const char *path)
{
	size_t len, o = 2;
	uint8_t *b = slurp(path, &len);
	int v[3], k = 0;
	if (!b || len < 16 || b[0] != 'P' || b[1] != '6') { free(b); return -1; }
	while (k < 3 && o < len) {
		if (b[o] == '#') { while (o < len && b[o] != '\n') o++; continue; }
		if (b[o] >= '0' && b[o] <= '9') { v[k] = 0; while (o < len && b[o] >= '0' && b[o] <= '9') v[k] = v[k] * 10 + b[o++] - '0'; k++; continue; }
		o++;
	}
	o++;                                        /* the single whitespace after maxval */
	if (k < 3 || v[2] != 255 || o + (size_t)v[0] * v[1] * 3 > len) { free(b); return -1; }
	int x0 = (W - v[0]) / 2, y0 = (H - v[1]) / 2;
	for (int y = 0; y < v[1]; y++) {
		int dy = y0 + y;
		if (dy < 0 || dy >= H) continue;
		for (int x = 0; x < v[0]; x++) {
			int dx = x0 + x;
			if (dx < 0 || dx >= W) continue;
			memcpy(rgb + ((size_t)dy * W + dx) * 3, b + o + ((size_t)y * v[0] + x) * 3, 3);
		}
	}
	free(b);
	return 0;
}

/* the status band: one text line and the progress bar below it */
static int band_y, band_h;
static void draw_status(const char *s, int pct)
{
	struct font ft;
	char path[512];
	int big = H >= 720, bar_w = W * 36 / 100, bar_h = big ? 6 : 4;
	snprintf(path, sizeof path, "%s/font-%d.psf", dir, big ? 24 : 16);
	int have_font = font_load(&ft, path) == 0;
	int th = have_font ? ft.h : (big ? 24 : 16);
	band_y = H * 70 / 100;
	band_h = th + th / 2 + bar_h + 4;
	fill(0, band_y, W, band_h, 0x000000);
	if (have_font && s && *s)
		text(&ft, s, W / 2, band_y, 0x9aa3ad);
	if (pct >= 0) {
		int by = band_y + th + th / 2, bx = (W - bar_w) / 2;
		if (pct > 100) pct = 100;
		fill(bx, by, bar_w, bar_h, 0x1c2329);
		fill(bx, by, bar_w * pct / 100, bar_h, 0x3fa7e0);
	}
	free(ft.mem);
}

/* is the framebuffer console bound (a vtconsole "frame buffer device" with bind = 1)? */
static int fbcon_bound(void)
{
	DIR *d = opendir("/sys/class/vtconsole");
	struct dirent *e;
	int bound = 0;
	if (!d) return 0;
	while (!bound && (e = readdir(d))) {
		char p[300], name[128] = "", b[4] = "";
		FILE *f;
		if (strncmp(e->d_name, "vtcon", 5)) continue;
		snprintf(p, sizeof p, "/sys/class/vtconsole/%s/name", e->d_name);
		if ((f = fopen(p, "r"))) { if (!fgets(name, sizeof name, f)) name[0] = 0; fclose(f); }
		snprintf(p, sizeof p, "/sys/class/vtconsole/%s/bind", e->d_name);
		if ((f = fopen(p, "r"))) { if (!fgets(b, sizeof b, f)) b[0] = 0; fclose(f); }
		bound = strstr(name, "frame buffer") && b[0] == '1';
	}
	closedir(d);
	return bound;
}

static int fb_open(struct fb_var_screeninfo *var, struct fb_fix_screeninfo *fix)
{
	int fd = open(fbdev, O_RDWR | O_CLOEXEC);
	if (fd < 0) die(fbdev);
	if (ioctl(fd, FBIOGET_VSCREENINFO, var) || ioctl(fd, FBIOGET_FSCREENINFO, fix)) die("FBIOGET_*SCREENINFO");
	W = var->xres; H = var->yres;
	return fd;
}

static uint32_t chan(unsigned v, const struct fb_bitfield *b)
{
	return b->length ? ((uint32_t)v >> (8 - (b->length > 8 ? 8 : b->length))) << b->offset : 0;
}

/* write rows [y0, y1) of the frame to the framebuffer in its pixel format */
static void fb_write(int fd, const struct fb_var_screeninfo *var, const struct fb_fix_screeninfo *fix, int y0, int y1)
{
	int bpp = (var->bits_per_pixel + 7) / 8;
	uint8_t *row = malloc(fix->line_length);
	if (!row) die("malloc");
	if (bpp < 2 || bpp > 4) { errno = EINVAL; die("unsupported pixel depth"); }
	for (int y = y0; y < y1 && y < H; y++) {
		memset(row, 0, fix->line_length);
		for (int x = 0; x < W; x++) {
			const uint8_t *p = rgb + ((size_t)y * W + x) * 3;
			uint32_t px = chan(p[0], &var->red) | chan(p[1], &var->green) | chan(p[2], &var->blue);
			if (var->transp.length) px |= ((1u << var->transp.length) - 1) << var->transp.offset;
			memcpy(row + (size_t)x * bpp, &px, bpp);      /* little endian */
		}
		off_t off = (off_t)(y + var->yoffset) * fix->line_length + (off_t)var->xoffset * bpp;
		if (pwrite(fd, row, fix->line_length, off) < 0) die("write");
	}
	free(row);
}

/* PNG, 8-bit RGB, stored (uncompressed) deflate blocks: no zlib needed */
static uint32_t crc_tab[256];
static uint32_t crc(uint32_t c, const uint8_t *b, size_t n)
{
	if (!crc_tab[1])
		for (uint32_t i = 0; i < 256; i++) {
			uint32_t v = i;
			for (int k = 0; k < 8; k++) v = v & 1 ? 0xedb88320 ^ (v >> 1) : v >> 1;
			crc_tab[i] = v;
		}
	c = ~c;
	while (n--) c = crc_tab[(c ^ *b++) & 0xff] ^ (c >> 8);
	return ~c;
}
static void be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void chunk(FILE *f, const char *type, const uint8_t *d, size_t n)
{
	uint8_t h[8];
	be32(h, n); memcpy(h + 4, type, 4);
	uint32_t c = crc(crc(0, (const uint8_t *)type, 4), d, n);
	fwrite(h, 1, 8, f); fwrite(d, 1, n, f);
	be32(h, c); fwrite(h, 1, 4, f);
}
static int png_write(const char *path)
{
	size_t rowlen = (size_t)W * 3 + 1, raw = rowlen * H, nblk = (raw + 65534) / 65535;
	size_t zlen = 2 + raw + nblk * 5 + 4, o = 0;
	uint8_t *z = malloc(zlen), ihdr[13];
	uint32_t a = 1, b2 = 0;
	char tmp[600];
	FILE *f;
	if (!z) return -1;
	z[o++] = 0x78; z[o++] = 0x01;
	size_t left = raw, pos = 0;                  /* pos: offset in the filtered image */
	while (left) {
		size_t n = left > 65535 ? 65535 : left;
		z[o++] = left == n; z[o++] = n; z[o++] = n >> 8; z[o++] = ~n; z[o++] = ~n >> 8;
		for (size_t i = 0; i < n; i++, pos++) {
			size_t y = pos / rowlen, x = pos % rowlen;
			uint8_t v = x ? rgb[y * W * 3 + x - 1] : 0;       /* filter byte 0 = none */
			z[o++] = v;
			a = (a + v) % 65521; b2 = (b2 + a) % 65521;
		}
		left -= n;
	}
	be32(z + o, (b2 << 16) | a); o += 4;
	be32(ihdr, W); be32(ihdr + 4, H);
	ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = ihdr[11] = ihdr[12] = 0;
	snprintf(tmp, sizeof tmp, "%s.tmp", path);
	if (!(f = fopen(tmp, "wb"))) { free(z); return -1; }
	fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
	chunk(f, "IHDR", ihdr, 13);
	chunk(f, "IDAT", z, o);
	chunk(f, "IEND", NULL, 0);
	free(z);
	if (fclose(f) || rename(tmp, path)) return -1;
	return 0;
}

static void compose(const char *status, int pct)
{
	char path[512];
	rgb = calloc((size_t)W * H, 3);
	if (!rgb) die("calloc");
	snprintf(path, sizeof path, "%s/splash-%dx%d.ppm", dir, W, H);
	if (ppm_blit(path)) {
		/* another panel size: the largest image that fits, centred */
		static const int sz[][2] = { { 1280, 800 }, { 800, 480 } };
		for (unsigned i = 0; i < sizeof sz / sizeof sz[0]; i++) {
			if (sz[i][0] > W || sz[i][1] > H) continue;
			snprintf(path, sizeof path, "%s/splash-%dx%d.ppm", dir, sz[i][0], sz[i][1]);
			if (!ppm_blit(path)) break;
		}
	}
	draw_status(status, pct);
}

static void usage(void)
{
	fputs("usage: tsx-splash [-d DIR] [-f FB] [-s TEXT] [-p PCT] show|status|png FILE|console|size\n", stderr);
	exit(2);
}

int main(int argc, char **argv)
{
	const char *status = "", *cmd;
	int pct = -1, c, gw = 0, gh = 0;
	struct fb_var_screeninfo var;
	struct fb_fix_screeninfo fix;

	while ((c = getopt(argc, argv, "d:f:s:p:g:")) != -1)
		switch (c) {
		case 'd': dir = optarg; break;
		case 'f': fbdev = optarg; break;
		case 's': status = optarg; break;
		case 'p': pct = atoi(optarg); break;
		case 'g': if (sscanf(optarg, "%dx%d", &gw, &gh) != 2 || gw < 1 || gh < 1 || gw > 8192 || gh > 8192) usage(); break;
		default: usage();
		}
	if (optind >= argc) usage();
	cmd = argv[optind];

	if (!strcmp(cmd, "console")) {
		/* FBIOPUT_CON2FBMAP: the first call takes over all consoles */
		int fd = open(fbdev, O_RDWR | O_CLOEXEC), ok = 0;
		if (fd < 0) die(fbdev);
		for (unsigned con = 1; con <= 12; con++) {
			struct fb_con2fbmap m = { .console = con, .framebuffer = 0 };
			if (!ioctl(fd, FBIOPUT_CON2FBMAP, &m)) ok = 1;
		}
		close(fd);
		if (!ok) die("FBIOPUT_CON2FBMAP");
		return 0;
	}

	if (gw && (!strcmp(cmd, "size") || !strcmp(cmd, "png"))) {
		W = gw; H = gh;
	} else if (strcmp(cmd, "show") && strcmp(cmd, "status") && strcmp(cmd, "size") && strcmp(cmd, "png")) {
		usage();
	} else {
		close(fb_open(&var, &fix));
	}
	if (!strcmp(cmd, "size")) {
		printf("%dx%d\n", W, H);
		return 0;
	}
	if (!strcmp(cmd, "png")) {
		if (optind + 1 >= argc) usage();
		compose(status, pct);
		if (png_write(argv[optind + 1])) die(argv[optind + 1]);
		return 0;
	}
	if (fbcon_bound()) return 0;            /* the text console has the screen */
	int fd = fb_open(&var, &fix);
	if (!strcmp(cmd, "show")) {
		compose(status, pct);
		/* the fbdev emulation programs the display on set_par: force it
		 * (nothing else did, fbcon is not bound), then unblank */
		var.activate = FB_ACTIVATE_NOW | FB_ACTIVATE_FORCE;
		var.xoffset = var.yoffset = 0;
		ioctl(fd, FBIOPUT_VSCREENINFO, &var);
		ioctl(fd, FBIOGET_VSCREENINFO, &var);
		fb_write(fd, &var, &fix, 0, H);
		ioctl(fd, FBIOBLANK, FB_BLANK_UNBLANK);
		return 0;
	}
	if (!strcmp(cmd, "status")) {
		rgb = calloc((size_t)W * H, 3);
		if (!rgb) die("calloc");
		draw_status(status, pct);
		fb_write(fd, &var, &fix, band_y, band_y + band_h);
		return 0;
	}
	usage();
	return 2;
}
