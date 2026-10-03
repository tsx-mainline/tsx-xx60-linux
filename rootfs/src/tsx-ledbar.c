/*
 * tsx-ledbar: RGB LED bar of the xx60.
 *
 * An STM32 on the internal USB port (14be:001b) drives the bar. Its
 * interface 1 takes Cresnet packets, one per USB transfer:
 *   analog join  : 00 05 14 JH JL VH VL   joins 3/4/5 = red/green/blue, V 0..100
 *   digital join : 00 03 00 JL JH|80*off  joins 0/1/2 = red/green/blue
 * (the vendor sysfs .../2-1:1.1/stm32_io took exactly these bytes).
 * The bar lights a color only while its digital join is on. The analog join
 * sets the level.
 *
 * Interface 0 is a text console of the STM32 (lines end with CR LF). The
 * "console" command sends one line there with libusb and prints the answer.
 * No kernel driver binds interface 0, so the LED driver stays bound.
 * tsx-ledbard uses it to check the LED driver chips after a plug-in and to
 * restart the STM32 when they did not start.
 *
 * Backends: when the kernel driver leds-crestron-stm32 is present, the tool
 * uses it (/sys/class/leds/tsx:rgb:bar, multi_intensity and brightness, and
 * the "raw" attribute for packets). Otherwise it uses libusb, which claims
 * interface 1 itself. --usb forces libusb and detaches the kernel driver while
 * the tool runs.
 *
 * Color model: the tool keeps the "wanted" color (set, on, off, boot) in
 * /run/tsx/ledbar.state. The screen state never changes the bar. "apply"
 * sends the wanted color again and starts the recorded effect again.
 *
 * Effects: the open bar firmware "TSX-LEDBAR" (USB string 4, the "firmware"
 * attribute of the kernel driver) runs effects on the bar itself. The "fx"
 * command sends them as console lines (FX FADE, BLINK, BREATHE, RAINBOW,
 * SMOOTH, CAP, OFF). The console is interface 0, so the kernel driver stays
 * bound to interface 1. The stock firmware has no effects, and "fx" refuses
 * to run. The state file records the running effect ("fx ..."). An effect
 * does not change the wanted color. The effect color lives in the record only,
 * and "fx off" shows the wanted color from before the effect. A host join
 * ends an effect on the bar, so a new wanted color (set, on, off, boot) ends
 * the effect and clears the record. "apply" starts the recorded effect
 * again, for example after a restart of the bar.
 *
 * The 16 LEDs: firmware TSX-LEDBAR 0.1.3 and later ("leds16" in the answer
 * to CAPS) sets each LED on its own. "led", "side" and "clear" send
 * LED SET, LED SIDE and LED CLEAR. The firmware copies the host color into
 * all 16 LEDs at the first LED SET or LED SIDE, so the tool does the same
 * with the wanted color and records the whole pattern in the state file
 * ("pattern" and 48 levels). The zone effects chase, fill, spectrum and
 * split also need 0.1.3. A LED command ends the effect on the bar and
 * clears the effect record. An effect on top of the pattern keeps the
 * pattern, and "fx off" shows the pattern again. A new wanted color ends
 * the pattern and the effect. "apply" sends the wanted color, then the
 * pattern, then the effect.
 *
 * Env overrides for tests: TSX_LEDBAR_SYSFS (LED dir), TSX_RUN_DIR,
 * TSX_LEDBAR_CONF. A test build (-DNO_LIBUSB) writes
 * console lines to the file TSX_LEDBAR_CONSOLE and answers as the firmware.
 * It answers CAPS with TSX_LEDBAR_CAPS (default: the words of 0.1.2) and
 * does not write the CAPS line to the file.
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
#include <strings.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#ifndef NO_LIBUSB
#include <libusb-1.0/libusb.h>
#endif

#define VID 0x14be
#define PID 0x001b
#define IO_IFACE 1
#define CONSOLE_IFACE 0
#define MAXPKT 257
#define JOIN_ANALOG_RED 3
#define JOIN_DIGITAL_RED 0
#define FX_FIRMWARE "TSX-LEDBAR"	/* firmware name prefix of our bar firmware */
#define FXLEN 96
#define LEDS_CAP "leds16"	/* the CAPS word of the firmware with the 16 LEDs */
#define NLEDS 16
#define NROWS 8

static const char *sysled = "/sys/class/leds/tsx:rgb:bar";
static const char *rundir = "/run/tsx";
static const char *conffile = "/etc/tsx/ledbar.conf";
static int dry_run, force_usb, verbose;

struct conf { int boot[3]; };
static struct conf C = { { 0, 0, 0 } };

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
		/* BLANK and BLANK_DIM of an old file are ignored, tsx-ledbard logs them */
	}
	fclose(f);
}

/* ---- state --------------------------------------------------------------- */
struct state { int want[3], last[3], out[3]; char fx[FXLEN]; int pat_on, pat[NLEDS][3]; };

static void state_path(char *p, size_t n) { snprintf(p, n, "%s/ledbar.state", rundir); }

/* "pattern" and 48 levels (R G B of LED 0 to 15). A short or bad line is no pattern. */
static void read_pattern(struct state *st, const char *s)
{
	int n = 0;
	for (; n < NLEDS * 3; n++) {
		char *e; long v = strtol(s, &e, 10);
		if (e == s || v < 0 || v > 100) break;
		st->pat[n / 3][n % 3] = (int)v;
		s = e;
	}
	st->pat_on = n == NLEDS * 3;
}

static int read_state(struct state *st)
{
	char p[PATH_MAX], line[512]; FILE *f;
	memset(st, 0, sizeof *st);
	st->last[0] = st->last[1] = st->last[2] = -1;
	state_path(p, sizeof p);
	if (!(f = fopen(p, "r"))) return -1;
	while (fgets(line, sizeof line, f)) {
		int *d = !strncmp(line, "want ", 5) ? st->want : !strncmp(line, "last ", 5) ? st->last :
			 !strncmp(line, "out ", 4) ? st->out : NULL;
		if (d) sscanf(strchr(line, ' '), "%d %d %d", &d[0], &d[1], &d[2]);
		if (!strncmp(line, "fx ", 3) && strncmp(line + 3, "none", 4)) {
			size_t l = strcspn(line + 3, "\n");
			if (l >= sizeof st->fx) l = sizeof st->fx - 1;
			memcpy(st->fx, line + 3, l);
			st->fx[l] = 0;
		}
		if (!strncmp(line, "pattern ", 8) && strncmp(line + 8, "none", 4))
			read_pattern(st, line + 8);
	}
	fclose(f);
	return 0;
}

static void write_state(const struct state *st, const char *backend)
{
	char p[PATH_MAX], tmp[PATH_MAX + 8]; FILE *f;
	mkdir(rundir, 0755);
	state_path(p, sizeof p); snprintf(tmp, sizeof tmp, "%s.tmp", p);
	if (!(f = fopen(tmp, "w"))) return;
	fprintf(f, "want %d %d %d\nlast %d %d %d\nout %d %d %d\nbackend %s\nfx %s\npattern",
		st->want[0], st->want[1], st->want[2], st->last[0], st->last[1], st->last[2],
		st->out[0], st->out[1], st->out[2], backend,
		st->fx[0] ? st->fx : "none");
	if (!st->pat_on) fputs(" none", f);
	for (int i = 0; st->pat_on && i < NLEDS; i++)
		fprintf(f, " %d %d %d", st->pat[i][0], st->pat[i][1], st->pat[i][2]);
	fputc('\n', f);
	fclose(f);
	rename(tmp, p);
}

static void output_for(const int *want, int *out)
{
	for (int i = 0; i < 3; i++) out[i] = want[i];
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
static int usb_iface = IO_IFACE;	/* the interface that usb_open() claimed */

static void usb_close(void)
{
	if (uh) { libusb_release_interface(uh, usb_iface); libusb_close(uh); uh = NULL; }
	if (uctx) { libusb_exit(uctx); uctx = NULL; }
	ep_out = ep_in = 0;
}

static int usb_open(int iface)
{
	if (uh && usb_iface == iface) return 0;
	usb_close();
	usb_iface = iface;
	if (libusb_init(&uctx)) return -EIO;
	uh = libusb_open_device_with_vid_pid(uctx, VID, PID);
	if (!uh) return -ENODEV;
	libusb_set_auto_detach_kernel_driver(uh, 1);
	int r = libusb_claim_interface(uh, usb_iface);
	if (r) { fprintf(stderr, "tsx-ledbar: claim interface %d: %s\n", usb_iface, libusb_strerror(r)); return -EBUSY; }
	struct libusb_config_descriptor *cd;
	if (libusb_get_active_config_descriptor(libusb_get_device(uh), &cd)) return -EIO;
	for (int i = 0; i < cd->bNumInterfaces; i++) {
		const struct libusb_interface_descriptor *id = &cd->interface[i].altsetting[0];
		if (id->bInterfaceNumber != usb_iface) continue;
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

static int usb_xfer(unsigned char ep, int is_int, unsigned char *buf, int n, int *got, int ms)
{
	return is_int ? libusb_interrupt_transfer(uh, ep, buf, n, got, ms)
		      : libusb_bulk_transfer(uh, ep, buf, n, got, ms);
}

static int usb_send(const unsigned char *p, int n)
{
	int r = usb_open(IO_IFACE), got = 0;
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
	int r = usb_open(IO_IFACE);
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

/*
 * One line on the console (interface 0): drop old output, send LINE CR LF,
 * then print the answer until it is quiet for 300 ms or MS have passed.
 * With ANS, the answer goes there (N bytes at most) instead, and the first
 * full line ends it. The STM32 can drop off the bus during the answer
 * ("reboot"). That ends the answer and is no error.
 */
static int usb_console(const char *line, int ms, char *ans, size_t ans_n)
{
	int r = usb_open(CONSOLE_IFACE), got;
	size_t alen = 0;
	if (ans) ans[0] = 0;
	if (r) return r;
	if (!ep_in) die("console: no IN endpoint");
	unsigned char in[512], out[MAXPKT];
	while (!usb_xfer(ep_in, in_int, in, sizeof in, &got, 100) && got > 0)
		;
	int n = snprintf((char *)out, sizeof out, "%s\r\n", line);
	if (n >= (int)sizeof out) die("console: line too long");
	r = usb_xfer(ep_out, out_int, out, n, &got, 1000);
	if (r) { fprintf(stderr, "tsx-ledbar: console write: %s\n", libusb_strerror(r)); return -EIO; }
	int quiet = 0, any = 0;
	for (int left = ms; left > 0; left -= 100) {
		r = usb_xfer(ep_in, in_int, in, sizeof in, &got, 100);
		if (r && r != LIBUSB_ERROR_TIMEOUT) break;
		if (!r && got > 0) {
			for (int i = 0; i < got; i++) {
				if (in[i] == '\r') continue;
				if (!ans) putchar(in[i]);
				else if (alen + 1 < ans_n) { ans[alen++] = in[i]; ans[alen] = 0; }
			}
			any = 1; quiet = 0;
			if (ans && alen && ans[alen - 1] == '\n') break;
		} else if (any && (quiet += 100) >= 300) break;
	}
	if (!ans) putchar('\n');
	return 0;
}

/* String 4 of the bar: the firmware name. */
static int usb_firmware(char *buf, size_t n)
{
	libusb_context *c; libusb_device_handle *h; int r = -ENODEV;
	if (libusb_init(&c)) return -EIO;
	if ((h = libusb_open_device_with_vid_pid(c, VID, PID))) {
		if (libusb_get_string_descriptor_ascii(h, 4, (unsigned char *)buf, (int)n) > 0) r = 0;
		libusb_close(h);
	}
	libusb_exit(c);
	return r;
}
#else
static int usb_send(const unsigned char *p, int n) { (void)p; (void)n; return -ENOSYS; }
static int usb_read_loop(int ms) { (void)ms; return -ENOSYS; }
static void usb_close(void) {}
static int usb_firmware(char *buf, size_t n) { (void)buf; (void)n; return -ENODEV; }
/*
 * Test build: append the line to $TSX_LEDBAR_CONSOLE and answer as the bar
 * firmware ("fx test", or the text of $TSX_LEDBAR_ANSWER).
 */
static int usb_console(const char *line, int ms, char *ans, size_t ans_n)
{
	const char *p = getenv("TSX_LEDBAR_CONSOLE"), *a = getenv("TSX_LEDBAR_ANSWER"); FILE *f;
	(void)ms;
	if (!p) return -ENOSYS;
	if (!strcmp(line, "CAPS")) {
		const char *c = getenv("TSX_LEDBAR_CAPS");
		a = c ? c : "tsx-ledbar fade blink breathe rainbow smooth cap status";
	} else {
		if (!(f = fopen(p, "a"))) return -ENOSYS;
		fprintf(f, "%s\n", line);
		fclose(f);
		if (!a) a = !strncmp(line, "LED ", 4) ? "ok" : "fx test";
	}
	if (ans) snprintf(ans, ans_n, "%s\n", a);
	else puts(a);
	return 0;
}
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
	/* The kernel driver sends the digital joins itself. Here send both. */
	unsigned char p[8];
	for (int i = 0; i < 3; i++) {
		int e = send_pkt(p, enc_analog(p, JOIN_ANALOG_RED + i, rgb[i]));
		if (!e) e = send_pkt(p, enc_digital(p, JOIN_DIGITAL_RED + i, rgb[i] > 0));
		if (e) return e;
	}
	return 0;
}

/* ---- effects and LEDs (bar firmware TSX-LEDBAR) --------------------------- */
/* The firmware name: the "firmware" attribute of the kernel driver, else USB string 4. */
static int bar_firmware(char *buf, size_t n)
{
	buf[0] = 0;
	if (!force_usb && !sys_read("firmware", buf, n) && buf[0]) return 0;
	return dry_run ? -ENODEV : usb_firmware(buf, n);
}

static int fx_capable(void)
{
	char fw[128];
	return !bar_firmware(fw, sizeof fw) && !strncmp(fw, FX_FIRMWARE, strlen(FX_FIRMWARE));
}

/* The firmware has the 16 LEDs: TSX-LEDBAR, and "leds16" in the answer to CAPS. */
static int leds_capable(void)
{
	static int known = -1;
	char ans[256] = "", *w;
	if (known >= 0) return known;
	known = 0;
	if (!fx_capable() || usb_console("CAPS", 1500, ans, sizeof ans)) return known;
	for (w = strtok(ans, " \r\n"); w; w = strtok(NULL, " \r\n"))
		if (!strcmp(w, LEDS_CAP)) known = 1;
	return known;
}

static void __attribute__((noreturn)) need_leds(const char *what)
{
	char fw[128];
	if (bar_firmware(fw, sizeof fw)) fw[0] = 0;
	die("%s needs the LED bar firmware %s 0.1.3 or later with %s in CAPS (this bar: %s)",
	    what, FX_FIRMWARE, LEDS_CAP, fw[0] ? fw : "not found");
}

/*
 * Send LINE on the console. An answer that does not start with OK is a
 * refusal. QUIET drops the error message.
 */
static int bar_cmd(const char *line, const char *ok, int quiet)
{
	char ans[128] = "";
	int e;
	if (dry_run) { printf("console %s\n", line); return 0; }
	e = usb_console(line, 1500, ans, sizeof ans);
	if (!e && strncmp(ans, ok, strlen(ok))) {
		ans[strcspn(ans, "\n")] = 0;
		if (!quiet) fprintf(stderr, "tsx-ledbar: the LED bar refused '%s': '%s'\n", line, ans);
		e = -EPROTO;
	}
	return e;
}

/*
 * Send the effect REC ("breathe 100 0 0 4000") as the console line
 * "FX BREATHE 100 0 0 4000". The firmware answers "fx NAME".
 */
static int fx_send(const char *rec, int quiet)
{
	char line[FXLEN + 8];
	int n = snprintf(line, sizeof line, "FX %s", rec);
	for (int i = 3; i < n; i++) line[i] = toupper((unsigned char)line[i]);
	return bar_cmd(line, "fx ", quiet);
}

/* ---- the 16 LEDs ---------------------------------------------------------- */
static void led_name(int i, char *name)
{
	name[0] = i < NROWS ? 'R' : 'L';
	name[1] = (char)('1' + i % NROWS);
	name[2] = 0;
}

/* "R3", "l8" or "0".."15" to the LED index, -1 when bad (the rules of the firmware) */
static int led_id(const char *s, size_t n)
{
	int v = 0;
	if (n == 2 && strchr("RrLl", s[0]) && s[1] >= '1' && s[1] <= '8')
		return (s[0] == 'L' || s[0] == 'l' ? NROWS : 0) + s[1] - '1';
	if (n < 1 || n > 2) return -1;
	for (size_t i = 0; i < n; i++) {
		if (!isdigit((unsigned char)s[i])) return -1;
		v = v * 10 + s[i] - '0';
	}
	return v < NLEDS ? v : -1;
}

/* A LED selection: one LED (R3, L1, 5), a range (R1-R4, 8-11), a side (R or L) or ALL. */
static int leds_arg(const char *s, int *first, int *last)
{
	const char *dash = strchr(s, '-');
	int a, b;
	if (!strcasecmp(s, "ALL")) { *first = 0; *last = NLEDS - 1; return 0; }
	if (!strcasecmp(s, "R") || !strcasecmp(s, "L")) {
		*first = !strcasecmp(s, "L") ? NROWS : 0; *last = *first + NROWS - 1; return 0;
	}
	if (dash) { a = led_id(s, (size_t)(dash - s)); b = led_id(dash + 1, strlen(dash + 1)); }
	else a = b = led_id(s, strlen(s));
	if (a < 0 || b < 0) return -1;
	*first = a < b ? a : b; *last = a < b ? b : a;
	return 0;
}

/* The selection FIRST..LAST as the console names it: ALL, R1, R1-R4. */
static void leds_name(int first, int last, char *buf, size_t n)
{
	char a[4], b[4];
	led_name(first, a); led_name(last, b);
	if (first == 0 && last == NLEDS - 1) snprintf(buf, n, "ALL");
	else if (first == last) snprintf(buf, n, "%s", a);
	else snprintf(buf, n, "%s-%s", a, b);
}

/* Send the whole pattern: one LED SET for each run of LEDs with the same color. */
static int pattern_send(const struct state *st)
{
	char sel[16], line[64];
	for (int i = 0, j; i < NLEDS; i = j + 1) {
		for (j = i; j + 1 < NLEDS && !memcmp(st->pat[j + 1], st->pat[i], sizeof st->pat[i]); j++)
			;
		leds_name(i, j, sel, sizeof sel);
		snprintf(line, sizeof line, "LED SET %s %d %d %d", sel, st->pat[i][0], st->pat[i][1], st->pat[i][2]);
		int e = bar_cmd(line, "ok", 0);
		if (e) return e;
	}
	return 0;
}

/*
 * Set the wanted color (NULL keeps the old one), compute the output, send it
 * and record it. A new color ends the recorded pattern and effect, STOP_FX
 * ends the effect. Without them, the recorded pattern and effect start again
 * after the color. The joins end an effect. But after a fade, the bar keeps
 * the fade color when the joins do not change its host color. So "FX OFF"
 * follows the joins. With a pattern, "FX OFF" alone goes back to it.
 */
static int apply(const int *want, int stop_fx)
{
	struct state st; read_state(&st);
	int had_fx = st.fx[0] != 0, had_pat = st.pat_on, e, e_fx = 0;
	if (want) {
		memcpy(st.want, want, sizeof st.want);
		if (want[0] || want[1] || want[2]) memcpy(st.last, want, sizeof st.last);
		st.pat_on = 0;
	}
	if (want || stop_fx) st.fx[0] = 0;
	if (had_fx && !fx_capable()) st.fx[0] = had_fx = 0;	/* the bar runs another firmware now */
	if (had_pat && !leds_capable()) st.pat_on = had_pat = 0;
	output_for(st.want, st.out);
	if (!want && stop_fx && st.pat_on) {	/* fx off: the firmware goes back to the pattern */
		e = fx_send("off", 0);
		if (!dry_run && !e) write_state(&st, backend_name());
		return e;
	}
	e = send_rgb(st.out);
	if (!e && st.pat_on) e_fx = pattern_send(&st);
	else if (!e && had_pat) e_fx = bar_cmd("LED CLEAR", "ok", 1);	/* ends the effect too */
	if (!e && !e_fx && st.fx[0]) e_fx = fx_send(st.fx, 0);
	else if (!e && !e_fx && !had_pat && (had_fx || stop_fx)) {
		int e_off = fx_send("off", !stop_fx);
		if (stop_fx) e_fx = e_off;
	}
	/* With no bar, keep the wanted color: tsx-ledbard applies it at the plug-in. */
	if (!dry_run && (!e || e == -ENODEV)) write_state(&st, backend_name());
	return e ? e : e_fx;
}

/*
 * fx NAME ARGS: the value ranges of the firmware. COLOR: the first three
 * values are R G B. LEDS: the effect needs the 16 LEDs (0.1.3).
 */
static const struct fxdef {
	const char *name; int nmin, nmax, color, leds; int lo[6], hi[6];
} fxdefs[] = {
	{ "off", 0, 0, 0, 0, { 0 }, { 0 } },
	{ "fade", 4, 4, 1, 0, { 0, 0, 0, 0 }, { 100, 100, 100, 600000 } },
	{ "blink", 5, 5, 1, 0, { 0, 0, 0, 1, 1 }, { 100, 100, 100, 600000, 600000 } },
	{ "breathe", 4, 4, 1, 0, { 0, 0, 0, 100 }, { 100, 100, 100, 600000 } },
	{ "rainbow", 1, 2, 0, 0, { 100, 0 }, { 600000, 100 } },
	{ "smooth", 1, 1, 0, 0, { 0 }, { 60000 } },
	{ "cap", 1, 1, 0, 0, { 10 }, { 150 } },
	{ "chase", 4, 4, 1, 1, { 0, 0, 0, 100 }, { 100, 100, 100, 600000 } },
	{ "fill", 4, 4, 1, 1, { 0, 0, 0, 0 }, { 100, 100, 100, 100 } },
	{ "spectrum", 1, 2, 0, 1, { 100, 0 }, { 600000, 100 } },
	{ "split", 6, 6, 1, 1, { 0, 0, 0, 0, 0, 0 }, { 100, 100, 100, 100, 100, 100 } },
};

static void __attribute__((noreturn)) usage(void);
static int to_int(const char *s, int lo, int hi, const char *what);

static int cmd_fx(char **av, int n)
{
	const struct fxdef *d = NULL;
	char rec[FXLEN], fw[128], what[32];
	const char *mode = NULL;
	int v[6], len, e;
	for (size_t i = 0; n && i < sizeof fxdefs / sizeof fxdefs[0]; i++)
		if (!strcmp(av[0], fxdefs[i].name)) d = &fxdefs[i];
	/* spectrum MS [LEVEL] [ring|rows]: the layout of the hue circle (firmware default ring) */
	if (d && !strcmp(d->name, "spectrum") && n >= 3 &&
	    (!strcasecmp(av[n - 1], "ring") || !strcasecmp(av[n - 1], "rows")))
		mode = av[--n];
	if (n && (!d || n - 1 < d->nmin || n - 1 > d->nmax)) usage();
	if (bar_firmware(fw, sizeof fw) || strncmp(fw, FX_FIRMWARE, strlen(FX_FIRMWARE)))
		die("effects need the LED bar firmware %s (this bar: %s)", FX_FIRMWARE, fw[0] ? fw : "not found");
	if (!n) {	/* the running effect */
		char ans[128] = "";
		if (dry_run) { puts("console FX"); return 0; }
		e = usb_console("FX", 1500, ans, sizeof ans);
		if (!e) fputs(ans, stdout);
		return e;
	}
	len = snprintf(rec, sizeof rec, "%s", d->name);
	for (int i = 0; i < n - 1; i++) {
		v[i] = to_int(av[i + 1], d->lo[i], d->hi[i], d->name);
		len += snprintf(rec + len, sizeof rec - len, " %d", v[i]);
	}
	if (mode)	/* the level comes before the layout */
		snprintf(rec + len, sizeof rec - len, "%s %s", n == 2 ? " 100" : "", tolower((unsigned char)mode[1]) == 'i' ? "ring" : "rows");
	snprintf(what, sizeof what, "the effect %s", d->name);
	if (d->leds && !leds_capable()) need_leds(what);
	if (!strcmp(d->name, "off")) return apply(NULL, 1);
	/* smooth and cap are settings, no effect */
	if (!strcmp(d->name, "smooth") || !strcmp(d->name, "cap")) return fx_send(rec, 0);
	/* The effect color stays with the effect. The wanted color and the pattern are the base under it. */
	struct state st; read_state(&st);
	snprintf(st.fx, sizeof st.fx, "%s", rec);
	e = fx_send(rec, 0);
	if (!dry_run && !e) write_state(&st, backend_name());
	return e;
}

/*
 * led LEDS R G B, side R|L R G B, clear. The first LED command copies the
 * wanted color (the host color of the bar) into all 16 LEDs, as the firmware
 * does. A LED command ends the effect.
 */
static int cmd_leds(const char *cmd, char **av, int n)
{
	struct state st;
	char line[64], sel[16];
	int first = 0, last = -1, rgb[3], e;
	if (!strcmp(cmd, "clear") ? n != 0 : n != 4) usage();
	if (!strcmp(cmd, "led") && leds_arg(av[0], &first, &last))
		die("led: '%s' is not a LED (R1..R8, L1..L8, 0..15), a range (R1-R4), a side (R, L) or ALL", av[0]);
	if (!strcmp(cmd, "side")) {
		if (strcasecmp(av[0], "R") && strcasecmp(av[0], "L")) die("side: '%s' is not R or L", av[0]);
		leds_arg(av[0], &first, &last);
	}
	for (int i = 0; n && i < 3; i++) rgb[i] = to_int(av[i + 1], 0, 100, "color");
	if (!leds_capable()) need_leds(!strcmp(cmd, "clear") ? "clear" : !strcmp(cmd, "led") ? "led" : "side");
	read_state(&st);
	if (!strcmp(cmd, "clear")) {
		snprintf(line, sizeof line, "LED CLEAR");
		st.pat_on = 0;
	} else {
		if (!st.pat_on)
			for (int i = 0; i < NLEDS; i++) memcpy(st.pat[i], st.want, sizeof st.pat[i]);
		st.pat_on = 1;
		for (int i = first; i <= last; i++) memcpy(st.pat[i], rgb, sizeof st.pat[i]);
		if (!strcmp(cmd, "side")) snprintf(sel, sizeof sel, "SIDE %c", first ? 'L' : 'R');
		else { memcpy(sel, "SET ", 4); leds_name(first, last, sel + 4, sizeof sel - 4); }
		snprintf(line, sizeof line, "LED %s %d %d %d", sel, rgb[0], rgb[1], rgb[2]);
	}
	st.fx[0] = 0;
	e = bar_cmd(line, "ok", 0);
	if (!dry_run && !e) write_state(&st, backend_name());
	return e;
}

static void __attribute__((noreturn)) usage(void)
{
	fputs("usage: tsx-ledbar [-n] [-v] [--usb] COMMAND\n"
	      "  set R G B          color, each 0..100\n"
	      "  on | off           last non-black color (else BOOT_COLOR) | black\n"
	      "  boot               BOOT_COLOR of /etc/tsx/ledbar.conf\n"
	      "  apply              send the wanted color, the recorded pattern and the recorded effect again\n"
	      "  get                print wanted/last/output color, the running effect and the LED pattern\n"
	      "  analog JOIN VALUE  one analog join packet (3/4/5 = red/green/blue level)\n"
	      "  digital JOIN on|off  one digital join packet (0/1/2 = red/green/blue)\n"
	      "  raw HEX...         any Cresnet packet, e.g. raw 00 05 14 00 03 00 64\n"
	      "  read [MS]          print packets from the STM32 (libusb, default 2000 ms)\n"
	      "  console LINE [MS]  send LINE to the STM32 console (interface 0), print the answer\n"
	      "                     (default 1500 ms), e.g. console 'tlcoutmode red 0'\n"
	      "  info               backend and device details\n"
	      "  fw                 firmware name of the bar, \"effects yes\" for TSX-LEDBAR,\n"
	      "                     \"leds yes\" for TSX-LEDBAR 0.1.3 and later (the 16 LEDs)\n"
	      "  fx                 print the running effect (firmware TSX-LEDBAR only)\n"
	      "  fx fade R G B MS   fade to a color (MS 0..600000)\n"
	      "  fx blink R G B ON OFF  blink a color (ms on, ms off)\n"
	      "  fx breathe R G B MS  breathe a color (period MS 100..600000)\n"
	      "  fx rainbow MS [LEVEL]  hue cycle (period MS, LEVEL 0..100, default 100)\n"
	      "  fx smooth MS       ramp each new color over MS (0..60000, 0 = at once)\n"
	      "  fx cap PERCENT     power cap of the three colors (10..150)\n"
	      "  fx chase R G B MS  a dot runs down both sides, MS for one run (100..600000) (0.1.3)\n"
	      "  fx fill R G B PERCENT  a level bar from the bottom up, PERCENT 0..100 (0.1.3)\n"
	      "  fx spectrum MS [LEVEL] [ring|rows]  the hue circle on the bar (MS 100..600000,\n"
	      "                     ring: around the bar (default), rows: along each side) (0.1.3)\n"
	      "  fx split R G B R G B  the first color on the right side, the second on the left (0.1.3)\n"
	      "  fx off             end the effect, show the pattern or the wanted color from before it\n"
	      "  led LEDS R G B     set LEDs of the pattern: R1..R8, L1..L8 (top to bottom), 0..15,\n"
	      "                     a range (R1-R4), a side (R, L) or ALL (0.1.3)\n"
	      "  side R|L R G B     set one side of the pattern (0.1.3)\n"
	      "  clear              drop the pattern, show the wanted color (0.1.3)\n"
	      "                     A new color (set, on, off, boot) ends the pattern and the effect.\n"
	      "                     A LED command ends the effect. apply starts both again\n"
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
		e = apply(rgb, 0);
	} else if (!strcmp(cmd, "on")) {
		struct state st; read_state(&st);
		e = apply(st.last[0] >= 0 && (st.last[0] || st.last[1] || st.last[2]) ? st.last : C.boot, 0);
	} else if (!strcmp(cmd, "off")) {
		int z[3] = { 0, 0, 0 }; e = apply(z, 0);
	} else if (!strcmp(cmd, "boot")) {
		e = apply(C.boot, 0);
	} else if (!strcmp(cmd, "apply")) {
		e = apply(NULL, 0);
	} else if (!strcmp(cmd, "fx")) {
		e = cmd_fx(av, n);
	} else if (!strcmp(cmd, "led") || !strcmp(cmd, "side") || !strcmp(cmd, "clear")) {
		e = cmd_leds(cmd, av, n);
	} else if (!strcmp(cmd, "fw")) {
		char fw[128];
		if (bar_firmware(fw, sizeof fw)) { puts("firmware unknown\neffects no\nleds no"); e = -ENODEV; }
		else printf("firmware %s\neffects %s\nleds %s\n", fw, fx_capable() ? "yes" : "no", leds_capable() ? "yes" : "no");
	} else if (!strcmp(cmd, "get")) {
		struct state st;
		if (read_state(&st)) { puts("unknown (no state yet)"); return 0; }
		printf("want %d %d %d\nlast %d %d %d\nout %d %d %d\nfx %s\nleds %s\n", st.want[0], st.want[1], st.want[2],
		       st.last[0], st.last[1], st.last[2], st.out[0], st.out[1], st.out[2], st.fx[0] ? st.fx : "none",
		       st.pat_on ? "pattern" : "host");
		for (int i = 0; st.pat_on && i < NLEDS; i++) {
			char nm[4]; led_name(i, nm);
			printf("led %s %d %d %d\n", nm, st.pat[i][0], st.pat[i][1], st.pat[i][2]);
		}
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
	} else if (!strcmp(cmd, "console")) {
		if (n < 1 || n > 2) usage();
		if (dry_run) printf("console %s\n", av[0]);
		else e = usb_console(av[0], n == 2 ? to_int(av[1], 100, 60000, "ms") : 1500, NULL, 0);
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
		printf("config BOOT_COLOR=%d,%d,%d\n", C.boot[0], C.boot[1], C.boot[2]);
	} else usage();

	usb_close();
	if (e) { fprintf(stderr, "tsx-ledbar: %s: %s\n", cmd, e == -ENODEV ? "LED bar not found (lsusb: 14be:001b?)" : strerror(-e)); return 1; }
	return 0;
}
