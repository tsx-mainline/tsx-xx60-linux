/*
 * tsx-ledbar: RGB LED bar of the xx60.
 *
 * An STM32 on the internal USB port (14be:001b) drives the bar. Its
 * interface 1 takes Cresnet packets, one per USB transfer:
 *   analog join  : 00 05 14 JH JL VH VL   joins 3/4/5 = red/green/blue, V 0..100
 *   digital join : 00 03 00 JL JH|80*off  joins 0/1/2 = red/green/blue
 * (the vendor sysfs .../2-1:1.1/stm32_io took exactly these bytes).
 *
 * Backends: when the kernel driver leds-crestron-stm32 is present, the tool
 * uses it (/sys/class/leds/tsx:rgb:bar, multi_intensity and brightness, and
 * the "raw" attribute for packets). Otherwise it uses libusb, which claims
 * interface 1 itself. --usb forces libusb and detaches the kernel driver while
 * the tool runs.
 *
 * Color model: the tool keeps the "wanted" color (set, on, off, boot) in
 * /run/tsx/ledbar.state. The output is the wanted color, scaled by the
 * screen state of tsx-idled (/run/tsx-idled.state "blank"). BLANK=off|dim|keep
 * and BLANK_DIM (percent) in /etc/tsx/ledbar.conf control the scaling.
 * "apply" applies the color again. The tsx-ledbar service runs it when the
 * screen blanks or wakes.
 *
 * Env overrides for tests: TSX_LEDBAR_SYSFS (LED dir), TSX_RUN_DIR,
 * TSX_IDLED_STATE, TSX_LEDBAR_CONF.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#ifndef NO_LIBUSB
#include <libusb-1.0/libusb.h>
#endif

#define VID 0x14be
#define PID 0x001b
#define IO_IFACE 1
#define MAXPKT 257
#define JOIN_ANALOG_RED 3
#define JOIN_DIGITAL_RED 0

static const char *sysled = "/sys/class/leds/tsx:rgb:bar";
static const char *rundir = "/run/tsx";
static const char *idled_state = "/run/tsx-idled.state";
static const char *conffile = "/etc/tsx/ledbar.conf";
static int dry_run, force_usb, verbose;

struct conf { int boot[3]; char blank[16]; int blank_dim; };
static struct conf C = { { 0, 0, 0 }, "off", 10 };

static void __attribute__((noreturn, format(printf, 1, 2))) die(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt);
	fputs("tsx-ledbar: ", stderr); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
	va_end(ap); exit(1);
}

/* ---- frame encoding ------------------------------------------------------ */
static int enc_analog(unsigned char *p, int join, int val)
{
	p[0] = 0x00; p[1] = 0x05; p[2] = 0x14;
	p[3] = (join >> 8) & 0xff; p[4] = join & 0xff;
	p[5] = (val >> 8) & 0xff; p[6] = val & 0xff;
	return 7;
}

static int enc_digital(unsigned char *p, int join, int on)
{
	p[0] = 0x00; p[1] = 0x03; p[2] = 0x00;
	p[3] = join & 0xff; p[4] = ((join >> 8) & 0x7f) | (on ? 0x00 : 0x80);
	return 5;
}

static int pkt_valid(const unsigned char *p, int n)
{
	return n >= 3 && n <= MAXPKT && p[1] == n - 2;
}

static void hexline(FILE *f, const unsigned char *p, int n)
{
	for (int i = 0; i < n; i++) fprintf(f, "%s%02x", i ? " " : "", p[i]);
	fputc('\n', f);
}

/* "00 05 14 ..", "00:05:14", "00051400030064", "0x00 0x05" */
static int parse_hex(char **argv, int argc, unsigned char *out)
{
	int n = 0, half = -1;
	for (int a = 0; a < argc; a++) {
		const char *s = argv[a];
		while (*s) {
			if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
				if (half >= 0) return -1;
				s += 2; continue;
			}
			if (isspace((unsigned char)*s) || *s == ':' || *s == ',' || *s == '-') {
				if (half >= 0) { out[n++] = half; half = -1; }
				s++; continue;
			}
			if (!isxdigit((unsigned char)*s)) return -1;
			int v = isdigit((unsigned char)*s) ? *s - '0' : (tolower((unsigned char)*s) - 'a' + 10);
			if (half < 0) half = v;
			else { if (n >= MAXPKT) return -1; out[n++] = half << 4 | v; half = -1; }
			s++;
		}
		if (half >= 0) { if (n >= MAXPKT) return -1; out[n++] = half; half = -1; }
	}
	return n;
}

/* ---- config -------------------------------------------------------------- */
static int clamp100(int v) { return v < 0 ? 0 : v > 100 ? 100 : v; }

static int parse_rgb(const char *s, int *rgb)
{
	int r, g, b; char tail;
	if (sscanf(s, " %d %d %d %c", &r, &g, &b, &tail) == 3 ||
	    sscanf(s, " %d,%d,%d %c", &r, &g, &b, &tail) == 3) {
		if (r < 0 || g < 0 || b < 0 || r > 100 || g > 100 || b > 100) return -1;
		rgb[0] = r; rgb[1] = g; rgb[2] = b; return 0;
	}
	return -1;
}

static char *trim(char *s)
{
	while (isspace((unsigned char)*s)) s++;
	char *e = s + strlen(s);
	while (e > s && isspace((unsigned char)e[-1])) *--e = 0;
	if (e - s >= 2 && (*s == '"' || *s == '\'') && e[-1] == *s) { e[-1] = 0; s++; }
	return s;
}

static void load_conf(void)
{
	FILE *f = fopen(conffile, "r"); char line[256];
	if (!f) return;
	while (fgets(line, sizeof line, f)) {
		char *s = trim(line), *eq;
		if (!*s || *s == '#' || !(eq = strchr(s, '='))) continue;
		*eq = 0; char *k = trim(s), *v = trim(eq + 1);
		if (!strcmp(k, "BOOT_COLOR")) { if (parse_rgb(v, C.boot)) fprintf(stderr, "tsx-ledbar: bad BOOT_COLOR '%s'\n", v); }
		else if (!strcmp(k, "BLANK")) snprintf(C.blank, sizeof C.blank, "%s", v);
		else if (!strcmp(k, "BLANK_DIM")) C.blank_dim = clamp100(atoi(v));
	}
	fclose(f);
}

/* ---- state --------------------------------------------------------------- */
struct state { int want[3], last[3], out[3]; };

static void state_path(char *p, size_t n) { snprintf(p, n, "%s/ledbar.state", rundir); }

static int read_state(struct state *st)
{
	char p[PATH_MAX], line[128]; FILE *f;
	memset(st, 0, sizeof *st);
	st->last[0] = st->last[1] = st->last[2] = -1;
	state_path(p, sizeof p);
	if (!(f = fopen(p, "r"))) return -1;
	while (fgets(line, sizeof line, f)) {
		int *d = !strncmp(line, "want ", 5) ? st->want : !strncmp(line, "last ", 5) ? st->last :
			 !strncmp(line, "out ", 4) ? st->out : NULL;
		if (d) sscanf(strchr(line, ' '), "%d %d %d", &d[0], &d[1], &d[2]);
	}
	fclose(f);
	return 0;
}

static int screen_blank(void)
{
	char b[32] = ""; FILE *f = fopen(idled_state, "r");
	if (!f) return 0;
	if (!fgets(b, sizeof b, f)) b[0] = 0;
	fclose(f);
	return !strncmp(b, "blank", 5);
}

static void write_state(const struct state *st, const char *backend)
{
	char p[PATH_MAX], tmp[PATH_MAX + 8]; FILE *f;
	mkdir(rundir, 0755);
	state_path(p, sizeof p); snprintf(tmp, sizeof tmp, "%s.tmp", p);
	if (!(f = fopen(tmp, "w"))) return;
	fprintf(f, "want %d %d %d\nlast %d %d %d\nout %d %d %d\nscreen %s\nbackend %s\n",
		st->want[0], st->want[1], st->want[2], st->last[0], st->last[1], st->last[2],
		st->out[0], st->out[1], st->out[2], screen_blank() ? "blank" : "awake", backend);
	fclose(f);
	rename(tmp, p);
}

static void output_for(const int *want, int *out)
{
	int pct = 100;
	if (screen_blank()) pct = !strcmp(C.blank, "keep") ? 100 : !strcmp(C.blank, "dim") ? C.blank_dim : 0;
	for (int i = 0; i < 3; i++) out[i] = (want[i] * pct + 50) / 100;
}

/* ---- backends ------------------------------------------------------------ */
static int have_sysfs(void)
{
	char p[PATH_MAX]; snprintf(p, sizeof p, "%s/multi_intensity", sysled);
	return !force_usb && access(p, W_OK) == 0;
}

static int sys_write(const char *attr, const void *buf, size_t n)
{
	char p[PATH_MAX]; snprintf(p, sizeof p, "%s/%s", sysled, attr);
	int fd = open(p, O_WRONLY | O_TRUNC);
	if (fd < 0) return -errno;
	ssize_t w = write(fd, buf, n);
	int e = w < 0 ? -errno : (size_t)w == n ? 0 : -EIO;
	close(fd);
	return e;
}

static int sys_read(const char *attr, char *buf, size_t n)
{
	char p[PATH_MAX]; snprintf(p, sizeof p, "%s/%s", sysled, attr);
	FILE *f = fopen(p, "r");
	if (!f) return -errno;
	if (!fgets(buf, n, f)) buf[0] = 0;
	fclose(f);
	buf[strcspn(buf, "\n")] = 0;
	return 0;
}

static int sys_set_rgb(const int *rgb)
{
	char idx[128] = "red green blue", s[64], cur[32] = "";
	int order[3] = { 0, 1, 2 }, k = 0;
	sys_read("multi_index", idx, sizeof idx);
	for (char *t = strtok(idx, " "); t && k < 3; t = strtok(NULL, " "), k++)
		order[k] = !strcmp(t, "red") ? 0 : !strcmp(t, "green") ? 1 : !strcmp(t, "blue") ? 2 : k;
	snprintf(s, sizeof s, "%d %d %d\n", rgb[order[0]], rgb[order[1]], rgb[order[2]]);
	int e = sys_write("multi_intensity", s, strlen(s));
	if (e) return e;
	sys_read("brightness", cur, sizeof cur);
	if (atoi(cur) != 100) e = sys_write("brightness", "100\n", 4);
	return e;
}

#ifndef NO_LIBUSB
static libusb_context *uctx;
static libusb_device_handle *uh;
static unsigned char ep_out, ep_in;
static int out_int, in_int;

static int usb_open(void)
{
	if (uh) return 0;
	if (libusb_init(&uctx)) return -EIO;
	uh = libusb_open_device_with_vid_pid(uctx, VID, PID);
	if (!uh) return -ENODEV;
	libusb_set_auto_detach_kernel_driver(uh, 1);
	int r = libusb_claim_interface(uh, IO_IFACE);
	if (r) { fprintf(stderr, "tsx-ledbar: claim interface %d: %s\n", IO_IFACE, libusb_strerror(r)); return -EBUSY; }
	struct libusb_config_descriptor *cd;
	if (libusb_get_active_config_descriptor(libusb_get_device(uh), &cd)) return -EIO;
	for (int i = 0; i < cd->bNumInterfaces; i++) {
		const struct libusb_interface_descriptor *id = &cd->interface[i].altsetting[0];
		if (id->bInterfaceNumber != IO_IFACE) continue;
		for (int e = 0; e < id->bNumEndpoints; e++) {
			const struct libusb_endpoint_descriptor *ed = &id->endpoint[e];
			int t = ed->bmAttributes & 3;
			if (t != LIBUSB_TRANSFER_TYPE_BULK && t != LIBUSB_TRANSFER_TYPE_INTERRUPT) continue;
			if ((ed->bEndpointAddress & 0x80) && !ep_in) { ep_in = ed->bEndpointAddress; in_int = t == LIBUSB_TRANSFER_TYPE_INTERRUPT; }
			else if (!(ed->bEndpointAddress & 0x80) && !ep_out) { ep_out = ed->bEndpointAddress; out_int = t == LIBUSB_TRANSFER_TYPE_INTERRUPT; }
		}
	}
	libusb_free_config_descriptor(cd);
	if (!ep_out) return -ENODEV;
	if (verbose) fprintf(stderr, "usb: out ep %02x (%s), in ep %02x (%s)\n", ep_out, out_int ? "int" : "bulk", ep_in, in_int ? "int" : "bulk");
	return 0;
}

static void usb_close(void)
{
	if (uh) { libusb_release_interface(uh, IO_IFACE); libusb_close(uh); uh = NULL; }
	if (uctx) { libusb_exit(uctx); uctx = NULL; }
}

static int usb_xfer(unsigned char ep, int is_int, unsigned char *buf, int n, int *got, int ms)
{
	return is_int ? libusb_interrupt_transfer(uh, ep, buf, n, got, ms)
		      : libusb_bulk_transfer(uh, ep, buf, n, got, ms);
}

static int usb_send(const unsigned char *p, int n)
{
	int r = usb_open(), got = 0;
	if (r) return r;
	unsigned char b[MAXPKT]; memcpy(b, p, n);
	r = usb_xfer(ep_out, out_int, b, n, &got, 1000);
	if (r) { fprintf(stderr, "tsx-ledbar: usb write: %s\n", libusb_strerror(r)); return -EIO; }
	/* Collect the answer if one comes quickly (verbose mode shows it). */
	if (ep_in) {
		unsigned char in[512];
		if (!usb_xfer(ep_in, in_int, in, sizeof in, &got, 50) && got > 0 && verbose) {
			fputs("rx ", stderr); hexline(stderr, in, got);
		}
	}
	return 0;
}

static int usb_read_loop(int ms)
{
	int r = usb_open();
	if (r) return r;
	if (!ep_in) die("no IN endpoint");
	unsigned char in[512]; int got, left = ms;
	while (left > 0) {
		int step = left < 250 ? left : 250;
		r = usb_xfer(ep_in, in_int, in, sizeof in, &got, step);
		if (!r && got > 0) hexline(stdout, in, got);
		else if (r && r != LIBUSB_ERROR_TIMEOUT) { fprintf(stderr, "tsx-ledbar: usb read: %s\n", libusb_strerror(r)); return -EIO; }
		fflush(stdout);
		left -= step;
	}
	return 0;
}
#else
static int usb_send(const unsigned char *p, int n) { (void)p; (void)n; return -ENOSYS; }
static int usb_read_loop(int ms) { (void)ms; return -ENOSYS; }
static void usb_close(void) {}
#endif

static const char *backend_name(void)
{
	return dry_run ? "dry-run" : have_sysfs() ? "kernel" : "libusb";
}

static int send_pkt(const unsigned char *p, int n)
{
	if (!pkt_valid(p, n)) die("invalid Cresnet packet (byte 1 must be length-2)");
	if (dry_run) { hexline(stdout, p, n); return 0; }
	if (have_sysfs()) return sys_write("raw", p, n);
	return usb_send(p, n);
}

static int send_rgb(const int *rgb)
{
	if (!dry_run && have_sysfs()) return sys_set_rgb(rgb);
	unsigned char p[8];
	for (int i = 0; i < 3; i++) {
		int e = send_pkt(p, enc_analog(p, JOIN_ANALOG_RED + i, rgb[i]));
		if (e) return e;
	}
	return 0;
}

/* Set the wanted color (NULL keeps the old one), compute the output, send it and record it. */
static int apply(const int *want)
{
	struct state st; read_state(&st);
	if (want) {
		memcpy(st.want, want, sizeof st.want);
		if (want[0] || want[1] || want[2]) memcpy(st.last, want, sizeof st.last);
	}
	output_for(st.want, st.out);
	int e = send_rgb(st.out);
	if (!dry_run && !e) write_state(&st, backend_name());
	return e;
}

static void __attribute__((noreturn)) usage(void)
{
	fputs("usage: tsx-ledbar [-n] [-v] [--usb] COMMAND\n"
	      "  set R G B          color, each 0..100 (screen-blank rule of ledbar.conf applies)\n"
	      "  on | off           last non-black color (else BOOT_COLOR) | black\n"
	      "  boot               BOOT_COLOR of /etc/tsx/ledbar.conf\n"
	      "  apply              re-send the wanted color for the current screen state\n"
	      "  get                print wanted/last/output color\n"
	      "  analog JOIN VALUE  one analog join packet (3/4/5 = red/green/blue level)\n"
	      "  digital JOIN on|off  one digital join packet (0/1/2 = red/green/blue)\n"
	      "  raw HEX...         any Cresnet packet, e.g. raw 00 05 14 00 03 00 64\n"
	      "  read [MS]          print packets from the STM32 (libusb, default 2000 ms)\n"
	      "  info               backend and device details\n"
	      "  -n = print the packets instead of sending; --usb = use libusb even with the kernel driver\n",
	      stderr);
	exit(2);
}

static int to_int(const char *s, int lo, int hi, const char *what)
{
	char *e; long v = strtol(s, &e, 0);
	if (*e || v < lo || v > hi) die("%s: '%s' is not %d..%d", what, s, lo, hi);
	return (int)v;
}

int main(int argc, char **argv)
{
	if (getenv("TSX_LEDBAR_SYSFS")) sysled = getenv("TSX_LEDBAR_SYSFS");
	if (getenv("TSX_RUN_DIR")) rundir = getenv("TSX_RUN_DIR");
	if (getenv("TSX_IDLED_STATE")) idled_state = getenv("TSX_IDLED_STATE");
	if (getenv("TSX_LEDBAR_CONF")) conffile = getenv("TSX_LEDBAR_CONF");
	int a = 1;
	for (; a < argc && argv[a][0] == '-' && argv[a][1]; a++) {
		if (!strcmp(argv[a], "-n") || !strcmp(argv[a], "--dry-run")) dry_run = 1;
		else if (!strcmp(argv[a], "--usb")) force_usb = 1;
		else if (!strcmp(argv[a], "-v")) verbose = 1;
		else usage();
	}
	if (a >= argc) usage();
	load_conf();
	const char *cmd = argv[a++]; int n = argc - a, e = 0;
	char **av = argv + a;

	/* Allow one writer at a time (service, ssh, MQTT bridge). */
	char lk[PATH_MAX]; snprintf(lk, sizeof lk, "%s/ledbar.lock", rundir);
	int lfd = dry_run ? -1 : (mkdir(rundir, 0755), open(lk, O_CREAT | O_RDWR, 0644));
	if (lfd >= 0) flock(lfd, LOCK_EX);

	if (!strcmp(cmd, "set")) {
		int rgb[3];
		if (n == 1) { if (parse_rgb(av[0], rgb)) die("set: want R G B (0..100)"); }
		else if (n == 3) for (int i = 0; i < 3; i++) rgb[i] = to_int(av[i], 0, 100, "color");
		else usage();
		e = apply(rgb);
	} else if (!strcmp(cmd, "on")) {
		struct state st; read_state(&st);
		e = apply(st.last[0] >= 0 && (st.last[0] || st.last[1] || st.last[2]) ? st.last : C.boot);
	} else if (!strcmp(cmd, "off")) {
		int z[3] = { 0, 0, 0 }; e = apply(z);
	} else if (!strcmp(cmd, "boot")) {
		e = apply(C.boot);
	} else if (!strcmp(cmd, "apply")) {
		e = apply(NULL);
	} else if (!strcmp(cmd, "get")) {
		struct state st;
		if (read_state(&st)) { puts("unknown (no state yet)"); return 0; }
		printf("want %d %d %d\nlast %d %d %d\nout %d %d %d\n", st.want[0], st.want[1], st.want[2],
		       st.last[0], st.last[1], st.last[2], st.out[0], st.out[1], st.out[2]);
	} else if (!strcmp(cmd, "analog")) {
		if (n != 2) usage();
		unsigned char p[8];
		e = send_pkt(p, enc_analog(p, to_int(av[0], 0, 0xffff, "join"), to_int(av[1], 0, 0xffff, "value")));
	} else if (!strcmp(cmd, "digital")) {
		if (n != 2 || (strcmp(av[1], "on") && strcmp(av[1], "off"))) usage();
		unsigned char p[8];
		e = send_pkt(p, enc_digital(p, to_int(av[0], 0, 0x7fff, "join"), !strcmp(av[1], "on")));
	} else if (!strcmp(cmd, "raw")) {
		unsigned char p[MAXPKT + 1];
		int len = parse_hex(av, n, p);
		if (len <= 0) die("raw: bad hex");
		e = send_pkt(p, len);
	} else if (!strcmp(cmd, "read")) {
		if (have_sysfs() && !force_usb) {
			char b[256] = ""; sys_read("rx_last", b, sizeof b);
			printf("rx_last (count hex): %s\n(kernel driver bound; --usb read to poll the endpoint yourself)\n", b);
		} else e = usb_read_loop(n ? to_int(av[0], 1, 3600000, "ms") : 2000);
	} else if (!strcmp(cmd, "info")) {
		printf("backend %s\nsysfs %s (%s)\n", backend_name(), sysled, have_sysfs() ? "present" : "absent");
		if (have_sysfs()) {
			char b[256];
			if (!sys_read("firmware", b, sizeof b)) printf("firmware %s\n", b);
			if (!sys_read("multi_index", b, sizeof b)) printf("multi_index %s\n", b);
			if (!sys_read("multi_intensity", b, sizeof b)) printf("multi_intensity %s\n", b);
			if (!sys_read("brightness", b, sizeof b)) printf("brightness %s\n", b);
			if (!sys_read("rx_last", b, sizeof b)) printf("rx_last %s\n", b);
		}
		printf("config BOOT_COLOR=%d,%d,%d BLANK=%s BLANK_DIM=%d\nscreen %s\n", C.boot[0], C.boot[1], C.boot[2],
		       C.blank, C.blank_dim, screen_blank() ? "blank" : "awake");
	} else usage();

	usb_close();
	if (e) { fprintf(stderr, "tsx-ledbar: %s: %s\n", cmd, e == -ENODEV ? "LED bar not found (lsusb: 14be:001b?)" : strerror(-e)); return 1; }
	return 0;
}
