/*
 * tsx-buttons: front-panel keys and key LEDs of the xx60.
 *
 * The five capacitive keys right of the LCD are touch-overlay buttons of the
 * FocalTech touch controller (edt-ft5x06 + touch-overlay, board DTS): they
 * arrive as KEY_F13..KEY_F17 on the touchscreen's event device. Their LEDs
 * are one common PWM brightness (/sys/class/leds/tsx:keypad, 0..255) and one
 * enable per key (/sys/class/leds/tsx:key1..5).
 *
 *  - Key events -> actions from /etc/tsx/buttons.conf (short press on
 *    release, long press at LONG_PRESS_MS, hold = long + repeat).
 *    Actions: exec, ha, ha-post, navigate, home, reload, blank, brightness,
 *    led, none. Optional HA event per press (HA_EVENT).
 *  - LED level follows the screen: LED_BLANK while tsx-idled has the screen
 *    blanked (/run/tsx-idled.state), LED_DAY / LED_NIGHT when awake; an
 *    override (control FIFO "led N", or the "led" action) replaces the
 *    day/night level until "led auto".
 *  - Brightness actions write /run/tsx/brightness, which tsx-idled uses in
 *    place of its day/night level, and set the backlight at once. The
 *    override ends at the next day/night change of the schedule.
 *  - Control FIFO /run/tsx/buttons.ctl (tsx-keypad is the CLI): "led N|auto",
 *    "key K on|off|auto", "press NAME [short|long|hold]", "reload", "status".
 *    State: /run/tsx/buttons.state.
 *  - While tsx-idled has the screen blanked it grabs all input devices, so a
 *    key press on a dark screen only wakes it (no action).
 *
 * Env overrides for tests: TSX_INPUT_DIR, TSX_LED_DIR, TSX_BACKLIGHT_DIR,
 * TSX_RUN_DIR, TSX_IDLED_STATE, TSX_HOSTNAME.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/input.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define MAXDEV 16
#define MAXBTN 16
#define MAXBIND 64
#define NLED 5
enum { EV_SHORT, EV_LONG, EV_HOLD, NEVT };
static const char *evname[NEVT] = { "short", "long", "hold" };

struct button { char name[32]; int code, led; int down, long_done; long long t_down, t_next; };
struct binding { int btn, evt; char action[512]; };

struct cfg {
	int long_ms, hold_ms, feedback_ms, ha_timeout;
	int led_day, led_night, led_blank, night_start, night_end;
	int bl_max;
	char ha_url[256], ha_token_file[PATH_MAX], ha_event[64], kiosk_url[512];
	char kiosk_conf[PATH_MAX], devtools[64], nav_fallback[16];
	char led_pwm[64], led_key[64], backlight[PATH_MAX];
	struct button btn[MAXBTN]; int nbtn;
	struct binding bind[MAXBIND]; int nbind;
};

static struct cfg C;
static const char *cfgfile = "/etc/tsx/buttons.conf";
static const char *indir = "/dev/input", *leddir = "/sys/class/leds", *bldir_base = "/sys/class/backlight";
static const char *rundir = "/run/tsx", *idled_state = "/run/tsx-idled.state";
static char hostname_s[64], bldir[PATH_MAX], hdrfile[PATH_MAX], ctlpath[PATH_MAX], statepath[PATH_MAX];
static int verbose, have_token;
static volatile sig_atomic_t sig_hup, sig_term;

struct dev { int fd; char path[PATH_MAX]; };
static struct dev devs[MAXDEV];
static int ndev;

/* runtime state */
static int blanked = -1, led_override = -1, key_override[NLED] = { -1, -1, -1, -1, -1 };
static int led_written = -2, key_written[NLED] = { -2, -2, -2, -2, -2 };
static long long feedback_until[NLED];
static int night_now = -1;
static char last_press[96] = "none";

static void logm(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt);
	fprintf(stderr, "tsx-buttons: "); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
	va_end(ap);
}

static long long now_ms(void)
{
	struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ---- key names ---------------------------------------------------------- */
static const struct { const char *n; int c; } keynames[] = {
	{ "KEY_F13", KEY_F13 }, { "KEY_F14", KEY_F14 }, { "KEY_F15", KEY_F15 },
	{ "KEY_F16", KEY_F16 }, { "KEY_F17", KEY_F17 }, { "KEY_F18", KEY_F18 },
	{ "KEY_F19", KEY_F19 }, { "KEY_F20", KEY_F20 }, { "KEY_PROG1", KEY_PROG1 },
	{ "KEY_PROG2", KEY_PROG2 }, { "KEY_PROG3", KEY_PROG3 }, { "KEY_PROG4", KEY_PROG4 },
	{ "KEY_POWER", KEY_POWER }, { "KEY_HOME", KEY_HOME }, { "KEY_BACK", KEY_BACK },
	{ "KEY_MUTE", KEY_MUTE }, { "KEY_VOLUMEUP", KEY_VOLUMEUP },
	{ "KEY_VOLUMEDOWN", KEY_VOLUMEDOWN },
};

static int keycode(const char *s)
{
	char *e; long v = strtol(s, &e, 0);
	if (*s && !*e && v > 0 && v < KEY_CNT) return (int)v;
	for (size_t i = 0; i < sizeof keynames / sizeof keynames[0]; i++)
		if (!strcasecmp(s, keynames[i].n)) return keynames[i].c;
	return -1;
}

/* ---- small file helpers ------------------------------------------------- */
static int read_int_path(const char *p)
{
	FILE *f; int v = -1;
	if ((f = fopen(p, "r"))) { if (fscanf(f, "%d", &v) != 1) v = -1; fclose(f); }
	return v;
}

static int write_str_path(const char *p, const char *s)
{
	FILE *f = fopen(p, "w");
	if (!f) return -1;
	fputs(s, f);
	return fclose(f);
}

static int write_int_path(const char *p, int v)
{
	char b[32]; snprintf(b, sizeof b, "%d\n", v);
	return write_str_path(p, b);
}

static char *trim(char *s)
{
	char *e;
	while (isspace((unsigned char)*s)) s++;
	for (e = s + strlen(s); e > s && isspace((unsigned char)e[-1]); ) *--e = 0;
	return s;
}

/* KEY=VALUE value: strip a trailing " # comment" and matching quotes */
static char *kv_value(char *v)
{
	char *e;
	if ((e = strchr(v, '#')) && (e == v || isspace((unsigned char)e[-1]))) *e = 0;
	v = trim(v); e = v + strlen(v);
	if ((*v == '"' || *v == '\'') && e > v + 1 && e[-1] == *v) { v++; e[-1] = 0; }
	return v;
}

/* ---- config ------------------------------------------------------------- */
static void cfg_defaults(struct cfg *c)
{
	memset(c, 0, sizeof *c);
	c->long_ms = 700; c->hold_ms = 300; c->feedback_ms = 120; c->ha_timeout = 10;
	c->led_day = 128; c->led_night = 24; c->led_blank = 0;
	c->night_start = -1; c->night_end = -1; c->bl_max = 23;
	strcpy(c->ha_token_file, "/etc/tsx/ha-token");
	strcpy(c->kiosk_conf, "/etc/kiosk.conf");
	strcpy(c->devtools, "127.0.0.1:9222");
	strcpy(c->nav_fallback, "restart");
	strcpy(c->led_pwm, "tsx:keypad"); strcpy(c->led_key, "tsx:key");
	strcpy(c->backlight, "auto");
}

/* the few kiosk.conf settings this daemon shares with the kiosk and tsx-idled */
static void kiosk_conf_load(struct cfg *c, int *ns, int *ne)
{
	FILE *f = fopen(c->kiosk_conf, "r"); char line[1024];
	strcpy(c->kiosk_url, "https://ha.example.org");
	*ns = 22; *ne = 7;
	if (!f) return;
	while (fgets(line, sizeof line, f)) {
		char *p = trim(line), *eq;
		if (*p == '#' || !(eq = strchr(p, '='))) continue;
		*eq = 0; char *v = kv_value(eq + 1);
		if (!strcmp(p, "KIOSK_URL") && *v) snprintf(c->kiosk_url, sizeof c->kiosk_url, "%s", v);
		else if (!strcmp(p, "NIGHT_START")) *ns = atoi(v);
		else if (!strcmp(p, "NIGHT_END")) *ne = atoi(v);
		else if (!strcmp(p, "BACKLIGHT_MAX")) c->bl_max = atoi(v);
		else if (!strcmp(p, "BACKLIGHT") && *v) snprintf(c->backlight, sizeof c->backlight, "%s", v);
	}
	fclose(f);
}

static int find_button(const char *name)
{
	for (int i = 0; i < C.nbtn; i++) if (!strcmp(C.btn[i].name, name)) return i;
	return -1;
}

static void origin_of(const char *url, char *out, size_t n)
{
	const char *p = strstr(url, "://");
	size_t len = strlen(url);
	if (p) { const char *s = strchr(p + 3, '/'); if (s) len = s - url; }
	snprintf(out, n, "%.*s", (int)len, url);
}

static void cfg_load(void)
{
	struct cfg c; FILE *f; char line[1024]; int lineno = 0, ns, ne;
	cfg_defaults(&c);
	if (!(f = fopen(cfgfile, "r"))) logm("no %s, using defaults (no buttons bound)", cfgfile);
	while (f && fgets(line, sizeof line, f)) {
		char *p = trim(line), *eq, *w[3], *rest;
		lineno++;
		if (!*p || *p == '#') continue;
		if (!strncmp(p, "button", 6) && isspace((unsigned char)p[6])) {
			/* button NAME KEYCODE [led=N] */
			char nm[32] = "", kc[32] = "", opt[32] = "";
			int n = sscanf(p + 6, "%31s %31s %31s", nm, kc, opt), code = keycode(kc);
			if (n < 2 || code < 0 || c.nbtn >= MAXBTN) { logm("%s:%d: bad button line", cfgfile, lineno); continue; }
			struct button *b = &c.btn[c.nbtn++];
			memset(b, 0, sizeof *b);
			snprintf(b->name, sizeof b->name, "%s", nm); b->code = code; b->led = 0;
			if (n == 3 && !strncmp(opt, "led=", 4)) b->led = atoi(opt + 4);
			if (b->led < 0 || b->led > NLED) b->led = 0;
			continue;
		}
		if (!strncmp(p, "on", 2) && isspace((unsigned char)p[2])) {
			/* on NAME short|long|hold ACTION... */
			rest = p + 2;
			for (int k = 0; k < 2; k++) {
				while (isspace((unsigned char)*rest)) rest++;
				w[k] = rest;
				while (*rest && !isspace((unsigned char)*rest)) rest++;
				if (*rest) *rest++ = 0;
			}
			w[2] = trim(rest);
			int bi = -1, ev = -1;
			for (int i = 0; i < c.nbtn; i++) if (!strcmp(c.btn[i].name, w[0])) bi = i;
			for (int i = 0; i < NEVT; i++) if (!strcmp(evname[i], w[1])) ev = i;
			if (bi < 0 || ev < 0 || !*w[2] || c.nbind >= MAXBIND) {
				logm("%s:%d: bad 'on' line (button defined above? short|long|hold? action?)", cfgfile, lineno);
				continue;
			}
			c.bind[c.nbind].btn = bi; c.bind[c.nbind].evt = ev;
			snprintf(c.bind[c.nbind].action, sizeof c.bind[0].action, "%s", w[2]);
			c.nbind++;
			continue;
		}
		if (!(eq = strchr(p, '='))) { logm("%s:%d: ignored", cfgfile, lineno); continue; }
		*eq = 0; char *k = trim(p), *v = kv_value(eq + 1);
#define I(n, f) if (!strcmp(k, n)) { c.f = atoi(v); continue; }
#define S(n, f) if (!strcmp(k, n)) { snprintf(c.f, sizeof c.f, "%s", v); continue; }
		I("LONG_PRESS_MS", long_ms) I("HOLD_REPEAT_MS", hold_ms) I("PRESS_FEEDBACK_MS", feedback_ms)
		I("HA_TIMEOUT", ha_timeout) I("LED_DAY", led_day) I("LED_NIGHT", led_night)
		I("LED_BLANK", led_blank) I("LED_NIGHT_START", night_start) I("LED_NIGHT_END", night_end)
		S("HA_URL", ha_url) S("HA_TOKEN_FILE", ha_token_file) S("HA_EVENT", ha_event)
		S("KIOSK_CONF", kiosk_conf) S("DEVTOOLS", devtools) S("NAV_FALLBACK", nav_fallback)
		S("LED_PWM", led_pwm) S("LED_KEY_PREFIX", led_key)
#undef I
#undef S
		logm("%s:%d: unknown setting %s", cfgfile, lineno, k);
	}
	if (f) fclose(f);
	kiosk_conf_load(&c, &ns, &ne);
	if (c.night_start < 0) c.night_start = ns;
	if (c.night_end < 0) c.night_end = ne;
	if (!c.ha_url[0]) origin_of(c.kiosk_url, c.ha_url, sizeof c.ha_url);
	if (c.long_ms < 100) c.long_ms = 100;
	if (c.hold_ms < 50) c.hold_ms = 50;
	C = c;

	/* HA token -> header file for curl -H @file (keeps it off the command line) */
	have_token = 0;
	FILE *t = fopen(C.ha_token_file, "r"); char tok[4096];
	if (t && fgets(tok, sizeof tok, t)) {
		char *tk = trim(tok);
		if (*tk) {
			int fd = open(hdrfile, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
			if (fd >= 0) { dprintf(fd, "Authorization: Bearer %s\n", tk); close(fd); have_token = 1; }
		}
	}
	if (t) fclose(t);
	memset(tok, 0, sizeof tok);
	if (!have_token) unlink(hdrfile);
	logm("%d buttons, %d bindings, long %d ms, LED day %d night %d blank %d (%02d-%02d h), HA %s (%s), event %s",
	     C.nbtn, C.nbind, C.long_ms, C.led_day, C.led_night, C.led_blank, C.night_start, C.night_end,
	     C.ha_url, have_token ? "token" : "no token", C.ha_event[0] ? C.ha_event : "off");
}

/* ---- schedule, LEDs, backlight ----------------------------------------- */
static int is_night(void)
{
	time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
	int h = tm.tm_hour, s = C.night_start, e = C.night_end;
	if (s == e) return 0;
	return s < e ? (h >= s && h < e) : (h >= s || h < e);
}

static void led_path(char *p, size_t n, const char *name)
{
	snprintf(p, n, "%s/%s/brightness", leddir, name);
}

static int led_target(void)
{
	if (blanked == 1) return C.led_blank;
	if (led_override >= 0) return led_override;
	return is_night() ? C.led_night : C.led_day;
}

static void write_state(void);

/* force: rewrite even if we think the value is there (someone else wrote it) */
static void leds_apply(int force)
{
	char p[PATH_MAX]; int lvl = led_target(); long long t = now_ms();
	if (lvl < 0) lvl = 0;
	if (lvl > 255) lvl = 255;
	led_path(p, sizeof p, C.led_pwm);
	if (force || lvl != led_written) {
		if (read_int_path(p) != lvl && write_int_path(p, lvl)) {
			if (led_written != -3) logm("cannot write %s: %s", p, strerror(errno));
			led_written = -3;
		} else {
			if (verbose && lvl != led_written) logm("keypad LED %d", lvl);
			led_written = lvl;
		}
	}
	for (int i = 0; i < NLED; i++) {
		char nm[80]; int on;
		snprintf(nm, sizeof nm, "%s%d", C.led_key, i + 1);
		on = lvl > 0 && key_override[i] != 0 && t >= feedback_until[i];
		if (!force && on == key_written[i]) continue;
		led_path(p, sizeof p, nm);
		if (read_int_path(p) != on) write_int_path(p, on);
		key_written[i] = on;
	}
	write_state();
}

static void find_backlight(void)
{
	DIR *d; struct dirent *e; char best[NAME_MAX + 1] = "";
	bldir[0] = 0;
	if (strcmp(C.backlight, "auto")) { snprintf(bldir, sizeof bldir, "%s", C.backlight); return; }
	if (!(d = opendir(bldir_base))) return;
	while ((e = readdir(d)))
		if (e->d_name[0] != '.' && (!best[0] || strcmp(e->d_name, best) < 0))
			snprintf(best, sizeof best, "%s", e->d_name);
	closedir(d);
	if (best[0]) snprintf(bldir, sizeof bldir, "%s/%s", bldir_base, best);
}

static void brightness_override_clear(void)
{
	char p[PATH_MAX]; snprintf(p, sizeof p, "%s/brightness", rundir);
	if (unlink(p) == 0) logm("brightness override cleared");
}

/* brightness +N | -N | N | auto */
static void do_brightness(const char *arg)
{
	char p[PATH_MAX + 32]; int cur, max, lvl;
	if (!strcmp(arg, "auto")) { brightness_override_clear(); return; }
	if (blanked == 1) return;
	if (!bldir[0]) find_backlight();
	if (!bldir[0]) { logm("brightness: no backlight"); return; }
	snprintf(p, sizeof p, "%s/max_brightness", bldir); max = read_int_path(p);
	snprintf(p, sizeof p, "%s/brightness", bldir); cur = read_int_path(p);
	if (max <= 0 || cur < 0) { logm("brightness: cannot read %s", bldir); return; }
	if (C.bl_max > 0 && max > C.bl_max) max = C.bl_max;
	lvl = (arg[0] == '+' || arg[0] == '-') ? cur + atoi(arg) : atoi(arg);
	if (lvl < 1) lvl = 1;
	if (lvl > max) lvl = max;
	/* tsx-idled uses this file instead of its day/night level */
	char o[PATH_MAX]; snprintf(o, sizeof o, "%s/brightness", rundir);
	write_int_path(o, lvl);
	if (write_int_path(p, lvl)) logm("brightness: write %s: %s", p, strerror(errno));
	logm("brightness %d -> %d (cap %d)", cur, lvl, max);
}

/* led +N | -N | N | auto | toggle */
static void do_led(const char *arg)
{
	int cur = led_override >= 0 ? led_override : (is_night() ? C.led_night : C.led_day);
	if (!strcmp(arg, "auto")) led_override = -1;
	else if (!strcmp(arg, "toggle")) led_override = cur > 0 ? 0 : (C.led_day > 0 ? C.led_day : 128);
	else if (!strcmp(arg, "off")) led_override = 0;
	else if (!strcmp(arg, "on")) led_override = C.led_day > 0 ? C.led_day : 128;
	else if (arg[0] == '+' || arg[0] == '-') led_override = cur + atoi(arg);
	else if (isdigit((unsigned char)arg[0])) led_override = atoi(arg);
	else { logm("led: bad argument '%s'", arg); return; }
	if (led_override > 255) led_override = 255;
	if (led_override < -1) led_override = 0;
	logm("keypad LED override %s", led_override < 0 ? "auto" : arg);
	leds_apply(0);
}

/* ---- tsx-idled ---------------------------------------------------------- */
static int idled_blanked(void)
{
	char b[32] = ""; FILE *f = fopen(idled_state, "r");
	if (!f) return 0;
	if (!fgets(b, sizeof b, f)) b[0] = 0;
	fclose(f);
	return !strncmp(b, "blank", 5);
}

static void signal_idled(int sig)
{
	pid_t pid = fork();
	if (pid == 0) {
		execlp("pkill", "pkill", sig == SIGUSR2 ? "-USR2" : "-USR1", "-x", "tsx-idled", (char *)NULL);
		_exit(127);
	}
}

static void do_blank(const char *arg)
{
	int want;
	if (!strcmp(arg, "on")) want = 1;
	else if (!strcmp(arg, "off")) want = 0;
	else if (!strcmp(arg, "toggle")) want = !idled_blanked();
	else { logm("blank: bad argument '%s'", arg); return; }
	signal_idled(want ? SIGUSR2 : SIGUSR1);
}

/* ---- JSON / HTTP / CDP ---------------------------------------------------- */
static void json_escape(const char *s, char *out, size_t n)
{
	size_t o = 0;
	for (; *s && o + 7 < n; s++) {
		unsigned char ch = (unsigned char)*s;
		if (ch == '"' || ch == '\\') { out[o++] = '\\'; out[o++] = ch; }
		else if (ch == '\n') { out[o++] = '\\'; out[o++] = 'n'; }
		else if (ch < 0x20) o += snprintf(out + o, n - o, "\\u%04x", ch);
		else out[o++] = ch;
	}
	out[o] = 0;
}

static int tcp_connect(const char *host, int port, int timeout_s)
{
	struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM }, *ai, *a;
	char ps[16]; int fd = -1;
	struct timeval tv = { .tv_sec = timeout_s };
	snprintf(ps, sizeof ps, "%d", port);
	if (getaddrinfo(host, ps, &hints, &ai)) return -1;
	for (a = ai; a; a = a->ai_next) {
		fd = socket(a->ai_family, a->ai_socktype | SOCK_CLOEXEC, 0);
		if (fd < 0) continue;
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
		setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
		if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
		close(fd); fd = -1;
	}
	freeaddrinfo(ai);
	return fd;
}

static int write_all(int fd, const void *b, size_t n)
{
	const char *p = b;
	while (n) { ssize_t w = write(fd, p, n); if (w <= 0) return -1; p += w; n -= w; }
	return 0;
}

/* parse a JSON string at *p (pointing at '"'); returns pointer after it */
static const char *json_str(const char *p, char *out, size_t n)
{
	size_t o = 0;
	if (*p != '"') return NULL;
	for (p++; *p && *p != '"'; p++) {
		char ch = *p;
		if (ch == '\\' && p[1]) {
			p++;
			switch (*p) {
			case 'n': ch = '\n'; break; case 't': ch = '\t'; break;
			case 'r': ch = '\r'; break; case 'b': ch = '\b'; break; case 'f': ch = '\f'; break;
			case 'u': ch = '?'; for (int k = 0; k < 4 && p[1]; k++) p++; break;
			default: ch = *p;
			}
		}
		if (o + 1 < n) out[o++] = ch;
	}
	if (n) out[o] = 0;
	return *p == '"' ? p + 1 : NULL;
}

/* skip any JSON value (non-string values of /json/list are flat) */
static const char *json_skip(const char *p)
{
	int depth = 0; char tmp[2];
	for (; *p; p++) {
		if (*p == '"') { if (!(p = json_str(p, tmp, sizeof tmp))) return NULL; p--; continue; }
		if (*p == '{' || *p == '[') depth++;
		else if (*p == '}' || *p == ']') { if (depth == 0) return p; depth--; }
		else if (*p == ',' && depth == 0) return p;
	}
	return p;
}

/* From Chromium's /json/list: the first "page" target's websocket URL. */
static int cdp_pick_target(const char *body, char *ws, size_t n)
{
	const char *p = strchr(body, '[');
	if (!p) return -1;
	for (p++; *p; ) {
		char type[32] = "", url[1024] = "", wsu[1024] = "", key[64], val[1024];
		while (*p && *p != '{' && *p != ']') p++;
		if (*p != '{') break;
		for (p++; *p && *p != '}'; ) {
			while (isspace((unsigned char)*p) || *p == ',') p++;
			if (*p != '"') break;
			if (!(p = json_str(p, key, sizeof key))) return -1;
			while (isspace((unsigned char)*p) || *p == ':') p++;
			if (*p == '"') {
				if (!(p = json_str(p, val, sizeof val))) return -1;
				if (!strcmp(key, "type")) snprintf(type, sizeof type, "%.31s", val);
				else if (!strcmp(key, "url")) snprintf(url, sizeof url, "%s", val);
				else if (!strcmp(key, "webSocketDebuggerUrl")) snprintf(wsu, sizeof wsu, "%s", val);
			} else if (!(p = json_skip(p))) return -1;
		}
		if (*p == '}') p++;
		if (!strcmp(type, "page") && wsu[0] && strncmp(url, "devtools://", 11)) {
			snprintf(ws, n, "%s", wsu);
			return 0;
		}
	}
	return -1;
}

static int http_get(const char *host, int port, const char *path, char *buf, size_t n)
{
	char req[512]; size_t got = 0; ssize_t r;
	int fd = tcp_connect(host, port, 2);
	if (fd < 0) return -1;
	snprintf(req, sizeof req, "GET %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\n\r\n", path, host, port);
	if (write_all(fd, req, strlen(req))) { close(fd); return -1; }
	while (got + 1 < n && (r = read(fd, buf + got, n - 1 - got)) > 0) got += r;
	close(fd);
	buf[got] = 0;
	return strncmp(buf, "HTTP/1.1 200", 12) ? -1 : 0;
}

/* does this CDP message carry "id": 1 (our only request)? */
static int cdp_is_reply(const char *m)
{
	const char *p = strstr(m, "\"id\"");
	if (!p) return 0;
	for (p += 4; isspace((unsigned char)*p) || *p == ':'; p++) ;
	return p[0] == '1' && !isdigit((unsigned char)p[1]);
}

/* One CDP command over the page websocket; result (text) into res. */
static int cdp_call(const char *msg, char *res, size_t rn)
{
	char host[64], body[65536], ws[1024], req[1280], *p, *hp;
	int port, fd;
	if (!C.devtools[0]) return -1;
	snprintf(host, sizeof host, "%s", C.devtools);
	if (!(p = strrchr(host, ':'))) return -1;
	*p = 0; port = atoi(p + 1);
	if (http_get(host, port, "/json/list", body, sizeof body)) return -1;
	if (!(p = strstr(body, "\r\n\r\n")) || cdp_pick_target(p + 4, ws, sizeof ws)) return -1;
	/* ws://host:port/devtools/page/<id> */
	if (strncmp(ws, "ws://", 5) || !(hp = strchr(ws + 5, '/'))) return -1;
	if ((fd = tcp_connect(host, port, 3)) < 0) return -1;
	snprintf(req, sizeof req, "GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
		 "Connection: Upgrade\r\nSec-WebSocket-Key: dHN4LWJ1dHRvbnMtbm9uY2U=\r\n"
		 "Sec-WebSocket-Version: 13\r\n\r\n", hp, host, port);
	char hdr[2048]; size_t got = 0; ssize_t r;
	if (write_all(fd, req, strlen(req))) goto fail;
	while (got + 1 < sizeof hdr && (r = read(fd, hdr + got, 1)) == 1) {
		got++; hdr[got] = 0;
		if (got >= 4 && !memcmp(hdr + got - 4, "\r\n\r\n", 4)) break;
	}
	if (strncmp(hdr, "HTTP/1.1 101", 12)) goto fail;
	/* masked text frame */
	size_t len = strlen(msg), h = 0; unsigned char fh[14], mask[4] = { 0x12, 0x34, 0x56, 0x78 };
	fh[h++] = 0x81;
	if (len < 126) fh[h++] = 0x80 | len;
	else if (len < 65536) { fh[h++] = 0x80 | 126; fh[h++] = len >> 8; fh[h++] = len & 0xff; }
	else goto fail;
	memcpy(fh + h, mask, 4); h += 4;
	char *m = malloc(len); if (!m) goto fail;
	for (size_t i = 0; i < len; i++) m[i] = msg[i] ^ mask[i & 3];
	int wr = write_all(fd, fh, h) || write_all(fd, m, len);
	free(m);
	if (wr) goto fail;
	/* read frames until the reply with our id arrives (events may come first) */
	for (int tries = 0; tries < 20; tries++) {
		unsigned char b2[2]; size_t plen; unsigned char ext[8];
		if (read(fd, b2, 2) != 2) goto fail;
		plen = b2[1] & 0x7f;
		if (plen == 126) { if (read(fd, ext, 2) != 2) goto fail; plen = ext[0] << 8 | ext[1]; }
		else if (plen == 127) goto fail;
		char *pl = malloc(plen + 1); size_t g = 0;
		if (!pl) goto fail;
		while (g < plen && (r = read(fd, pl + g, plen - g)) > 0) g += r;
		pl[g] = 0;
		int mine = cdp_is_reply(pl);
		if (mine && res) snprintf(res, rn, "%s", pl);
		free(pl);
		if (mine) break;
	}
	unsigned char cl[6] = { 0x88, 0x80, 0, 0, 0, 0 };
	write_all(fd, cl, sizeof cl);
	close(fd);
	return 0;
fail:
	close(fd);
	return -1;
}

static void absolute_url(const char *target, char *out, size_t n)
{
	char origin[512];
	if (strstr(target, "://")) { snprintf(out, n, "%s", target); return; }
	origin_of(C.kiosk_url, origin, sizeof origin);
	snprintf(out, n, "%s%s%s", origin, target[0] == '/' ? "" : "/", target);
}

/* runs in a child: navigate the kiosk; target NULL = reload */
static void navigate(const char *target, int home)
{
	char js[2048], jt[1100], esc[4096], msg[4608], res[1024] = "";
	if (target) {
		json_escape(target, jt, sizeof jt);
		/* same origin + HA frontend: in-app navigation (no page load) */
		snprintf(js, sizeof js,
			 "(function(t){var u=new URL(t,location.href);"
			 "if(u.origin===location.origin&&document.querySelector('home-assistant')){"
			 "history.pushState(null,'',u.pathname+u.search+u.hash);"
			 "window.dispatchEvent(new CustomEvent('location-changed',{detail:{replace:false}}));"
			 "return 'spa '+u.pathname;}location.href=u.href;return 'load '+u.href;})(\"%s\")", jt);
		json_escape(js, esc, sizeof esc);
		snprintf(msg, sizeof msg, "{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":"
			 "{\"expression\":\"%s\",\"returnByValue\":true}}", esc);
	} else {
		snprintf(msg, sizeof msg, "{\"id\":1,\"method\":\"Page.reload\",\"params\":{}}");
	}
	if (cdp_call(msg, res, sizeof res) == 0) {
		char *v = strstr(res, "\"value\":");
		logm("devtools: %s %s", target ? target : "reload", v ? v : "ok");
		return;
	}
	if (strcmp(C.nav_fallback, "restart")) {
		logm("devtools not reachable at %s (KIOSK_DEVTOOLS=1?), NAV_FALLBACK=%s: nothing done",
		     C.devtools, C.nav_fallback);
		return;
	}
	/* fallback: restart the kiosk on the URL (kiosk-session reads /run/tsx/kiosk-url) */
	char p[PATH_MAX], abs_url[1024];
	snprintf(p, sizeof p, "%s/kiosk-url", rundir);
	if (target && !home) {
		absolute_url(target, abs_url, sizeof abs_url);
		char line[1100]; snprintf(line, sizeof line, "%s\n", abs_url);
		write_str_path(p, line);
		chmod(p, 0644);
	} else if (home) {
		unlink(p);
	}
	logm("devtools not reachable at %s: restarting the kiosk on %s", C.devtools,
	     home ? C.kiosk_url : target ? abs_url : "the current URL");
	execlp("rc-service", "rc-service", "kiosk", "restart", (char *)NULL);
	logm("rc-service: %s", strerror(errno));
}

/* runs in a child: POST JSON to HA (curl, else busybox wget) */
static void ha_post(const char *path, const char *json)
{
	char url[1024], tmo[16];
	if (!have_token) { logm("HA: no token in %s, not calling %s", C.ha_token_file, path); return; }
	snprintf(url, sizeof url, "%s%s", C.ha_url, path);
	snprintf(tmo, sizeof tmo, "%d", C.ha_timeout);
	char hdr[PATH_MAX + 2]; snprintf(hdr, sizeof hdr, "@%s", hdrfile);
	if (verbose) logm("HA POST %s %s", url, json);
	execlp("curl", "curl", "-fsS", "-o", "/dev/null", "-m", tmo, "-X", "POST", "-H", hdr,
	       "-H", "Content-Type: application/json", "--data-raw", json, url, (char *)NULL);
	/* no curl: busybox wget (the token is then visible in ps to local users) */
	char tok[4200] = "", auth[4300]; FILE *f = fopen(hdrfile, "r");
	if (f) { if (fgets(tok, sizeof tok, f)) tok[strcspn(tok, "\n")] = 0; fclose(f); }
	snprintf(auth, sizeof auth, "%s", tok);
	execlp("wget", "wget", "-q", "-O", "/dev/null", "-T", tmo, "--header", auth,
	       "--header", "Content-Type: application/json", "--post-data", json, url, (char *)NULL);
	logm("HA: neither curl nor wget: %s", strerror(errno));
}

/* ---- actions ------------------------------------------------------------ */
static void run_child(void (*fn)(const char *, const char *), const char *a, const char *b)
{
	pid_t pid = fork();
	if (pid == 0) {
		signal(SIGCHLD, SIG_DFL);
		fn(a, b);
		_exit(0);
	}
	if (pid < 0) logm("fork: %s", strerror(errno));
}

static void child_exec(const char *cmd, const char *unused)
{
	(void)unused;
	setsid();
	execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
}

static void child_ha(const char *path, const char *json) { ha_post(path, json); }
static void child_nav(const char *target, const char *home) { navigate(target, home != NULL); }

static void run_action(const char *btn, const char *evt, const char *action)
{
	char a[512], *verb, *arg;
	snprintf(a, sizeof a, "%s", action);
	verb = a; arg = a;
	while (*arg && !isspace((unsigned char)*arg)) arg++;
	if (*arg) *arg++ = 0;
	arg = trim(arg);
	logm("%s %s: %s %s", btn, evt, verb, arg);
	if (!strcmp(verb, "exec")) {
		setenv("TSX_BUTTON", btn, 1); setenv("TSX_PRESS", evt, 1);
		run_child(child_exec, arg, NULL);
	} else if (!strcmp(verb, "ha") || !strcmp(verb, "ha-post")) {
		char path[512], *json = arg;
		while (*json && !isspace((unsigned char)*json)) json++;
		if (*json) *json++ = 0;
		json = trim(json);
		if (!*json) json = "{}";
		if (!strcmp(verb, "ha")) {
			char *s = strpbrk(arg, "./");      /* light.toggle or light/toggle */
			if (!s) { logm("ha: want DOMAIN.SERVICE, got '%s'", arg); return; }
			*s = 0;
			snprintf(path, sizeof path, "/api/services/%s/%s", arg, s + 1);
		} else {
			snprintf(path, sizeof path, "%s", arg);
		}
		run_child(child_ha, path, json);
	} else if (!strcmp(verb, "navigate")) {
		if (*arg) run_child(child_nav, arg, NULL);
	} else if (!strcmp(verb, "home")) {
		run_child(child_nav, C.kiosk_url, "home");
	} else if (!strcmp(verb, "reload")) {
		run_child(child_nav, NULL, NULL);
	} else if (!strcmp(verb, "blank")) {
		do_blank(*arg ? arg : "toggle");
	} else if (!strcmp(verb, "brightness")) {
		do_brightness(arg);
	} else if (!strcmp(verb, "led")) {
		do_led(arg);
	} else if (strcmp(verb, "none")) {
		logm("unknown action '%s'", verb);
	}
}

static void fire(int bi, int evt)
{
	struct button *b = &C.btn[bi];
	int n = 0;
	time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
	snprintf(last_press, sizeof last_press, "%s %s %02d:%02d:%02d", b->name, evname[evt],
		 tm.tm_hour, tm.tm_min, tm.tm_sec);
	for (int i = 0; i < C.nbind; i++)
		if (C.bind[i].btn == bi && C.bind[i].evt == evt) { run_action(b->name, evname[evt], C.bind[i].action); n++; }
	if (!n && verbose) logm("%s %s: not bound", b->name, evname[evt]);
	/* HA event per short/long press (not per hold repeat) */
	if (C.ha_event[0] && have_token && evt != EV_HOLD) {
		char path[128], json[256];
		snprintf(path, sizeof path, "/api/events/%s", C.ha_event);
		snprintf(json, sizeof json, "{\"panel\":\"%s\",\"button\":\"%s\",\"press\":\"%s\",\"code\":%d}",
			 hostname_s, b->name, evname[evt], b->code);
		run_child(child_ha, path, json);
	}
	write_state();
}

static int has_binding(int bi, int evt)
{
	for (int i = 0; i < C.nbind; i++) if (C.bind[i].btn == bi && C.bind[i].evt == evt) return 1;
	return 0;
}

static void key_event(int code, int value, long long t)
{
	for (int i = 0; i < C.nbtn; i++) {
		struct button *b = &C.btn[i];
		if (b->code != code) continue;
		if (value == 1 && !b->down) {
			b->down = 1; b->long_done = 0; b->t_down = t; b->t_next = t + C.long_ms;
			if (b->led && C.feedback_ms > 0) { feedback_until[b->led - 1] = t + C.feedback_ms; leds_apply(0); }
			if (verbose) logm("%s down", b->name);
		} else if (value == 0 && b->down) {
			b->down = 0;
			if (!b->long_done) fire(i, EV_SHORT);
		}
		/* value 2 (autorepeat) and a release without press (after a grab) are ignored */
	}
}

static void timers(long long t)
{
	for (int i = 0; i < C.nbtn; i++) {
		struct button *b = &C.btn[i];
		if (!b->down || t < b->t_next) continue;
		if (!b->long_done) {
			b->long_done = 1;
			fire(i, EV_LONG);
			if (has_binding(i, EV_HOLD)) fire(i, EV_HOLD);
		} else {
			fire(i, EV_HOLD);
		}
		b->t_next = t + C.hold_ms;
		if (!has_binding(i, EV_HOLD)) b->t_next = LLONG_MAX;
	}
	for (int i = 0; i < NLED; i++)
		if (feedback_until[i] && t >= feedback_until[i]) { feedback_until[i] = 0; leds_apply(0); }
}

/* ---- input devices ------------------------------------------------------ */
static int wants_device(int fd)
{
	unsigned long bits[(KEY_CNT + 8 * sizeof(long) - 1) / (8 * sizeof(long))];
	memset(bits, 0, sizeof bits);
	if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof bits), bits) < 0)
		return errno == ENOTTY || errno == EINVAL;   /* not evdev (test FIFO): take it */
	for (int i = 0; i < C.nbtn; i++) {
		int c = C.btn[i].code;
		if (bits[c / (8 * sizeof(long))] & (1UL << (c % (8 * sizeof(long))))) return 1;
	}
	return 0;
}

static void close_dev(int i) { close(devs[i].fd); devs[i] = devs[--ndev]; }

static void scan_devices(void)
{
	DIR *d = opendir(indir); struct dirent *e;
	if (!d) return;
	while ((e = readdir(d)) && ndev < MAXDEV) {
		char p[PATH_MAX]; int i, fd;
		if (strncmp(e->d_name, "event", 5)) continue;
		snprintf(p, sizeof p, "%s/%s", indir, e->d_name);
		for (i = 0; i < ndev && strcmp(devs[i].path, p); i++) ;
		if (i < ndev) continue;
		if ((fd = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC)) < 0) continue;
		if (!wants_device(fd)) { close(fd); continue; }
		char name[128] = "?";
		ioctl(fd, EVIOCGNAME(sizeof name), name);
		devs[ndev].fd = fd; snprintf(devs[ndev].path, sizeof devs[ndev].path, "%s", p);
		logm("using %s (%s)", p, name);
		ndev++;
	}
	closedir(d);
}

/* ---- state / control ---------------------------------------------------- */
static void write_state(void)
{
	char tmp[PATH_MAX + 8], keys[32] = ""; FILE *f;
	snprintf(tmp, sizeof tmp, "%s.tmp", statepath);
	if (!(f = fopen(tmp, "w"))) return;
	for (int i = 0; i < NLED; i++)
		snprintf(keys + strlen(keys), sizeof keys - strlen(keys), "%s%d", i ? " " : "",
			 key_written[i] < 0 ? -1 : key_written[i]);
	fprintf(f, "screen %s\nled %d %s\nkey_leds %s\nkey_override", blanked == 1 ? "blank" : "awake",
		led_written, led_override >= 0 ? "override" : blanked == 1 ? "blank" : is_night() ? "night" : "day", keys);
	for (int i = 0; i < NLED; i++)
		fprintf(f, " %s", key_override[i] < 0 ? "auto" : key_override[i] ? "on" : "off");
	char bo[PATH_MAX + 16]; snprintf(bo, sizeof bo, "%s/brightness", rundir);
	fprintf(f, "\nbrightness_override %d\ndevices %d\nlast %s\n", read_int_path(bo), ndev, last_press);
	fclose(f);
	rename(tmp, statepath);
}

static int key_index(const char *s)
{
	if (isdigit((unsigned char)s[0])) { int n = atoi(s); return n >= 1 && n <= NLED ? n - 1 : -1; }
	int b = find_button(s);
	return b >= 0 && C.btn[b].led ? C.btn[b].led - 1 : -1;
}

static void control(char *line)
{
	char *w[4] = { 0 }; int n = 0;
	for (char *tok = strtok(line, " \t\r\n"); tok && n < 4; tok = strtok(NULL, " \t\r\n")) w[n++] = tok;
	if (!n) return;
	if (!strcmp(w[0], "led") && n >= 2) do_led(w[1]);
	else if (!strcmp(w[0], "key") && n >= 3) {
		int k = key_index(w[1]);
		if (k < 0) { logm("ctl: no key LED '%s'", w[1]); return; }
		key_override[k] = !strcmp(w[2], "on") ? 1 : !strcmp(w[2], "off") ? 0 : -1;
		logm("ctl: key LED %d %s", k + 1, w[2]);
		leds_apply(0);
	} else if (!strcmp(w[0], "press") && n >= 2) {
		int b = find_button(w[1]), ev = EV_SHORT;
		if (n >= 3) for (int i = 0; i < NEVT; i++) if (!strcmp(w[2], evname[i])) ev = i;
		if (b < 0) { logm("ctl: no button '%s'", w[1]); return; }
		logm("ctl: press %s %s", w[1], evname[ev]);
		fire(b, ev);
	} else if (!strcmp(w[0], "reload")) sig_hup = 1;
	else if (!strcmp(w[0], "status")) leds_apply(1);
	else logm("ctl: unknown command '%s'", w[0]);
}

static void on_sig(int s) { if (s == SIGHUP) sig_hup = 1; else sig_term = 1; }

int main(int argc, char **argv)
{
	int opt, ctl = -1;
	struct sigaction sa = { .sa_handler = on_sig };
	while ((opt = getopt(argc, argv, "c:v")) != -1) {
		if (opt == 'c') cfgfile = optarg;
		else if (opt == 'v') verbose = 1;
		else { fprintf(stderr, "usage: %s [-c config] [-v]\n", argv[0]); return 2; }
	}
#define ENV(v, n) if (getenv(n)) v = getenv(n)
	ENV(indir, "TSX_INPUT_DIR"); ENV(leddir, "TSX_LED_DIR"); ENV(bldir_base, "TSX_BACKLIGHT_DIR");
	ENV(rundir, "TSX_RUN_DIR"); ENV(idled_state, "TSX_IDLED_STATE");
#undef ENV
	if (getenv("TSX_HOSTNAME")) snprintf(hostname_s, sizeof hostname_s, "%s", getenv("TSX_HOSTNAME"));
	else if (gethostname(hostname_s, sizeof hostname_s)) strcpy(hostname_s, "tsx");
	mkdir(rundir, 0755);
	snprintf(hdrfile, sizeof hdrfile, "%s/ha-auth.hdr", rundir);
	snprintf(ctlpath, sizeof ctlpath, "%s/buttons.ctl", rundir);
	snprintf(statepath, sizeof statepath, "%s/buttons.state", rundir);
	unlink(ctlpath);
	if (mkfifo(ctlpath, 0600) == 0) ctl = open(ctlpath, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (ctl < 0) logm("control FIFO %s: %s", ctlpath, strerror(errno));

	sigemptyset(&sa.sa_mask);
	sigaction(SIGHUP, &sa, NULL); sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
	signal(SIGCHLD, SIG_IGN);   /* action children reap themselves */
	signal(SIGPIPE, SIG_IGN);

	cfg_load(); find_backlight();
	scan_devices();
	blanked = idled_blanked(); night_now = is_night();
	leds_apply(1);

	long long last_scan = now_ms(), last_house = 0;
	while (!sig_term) {
		long long t = now_ms();
		if (sig_hup) {
			sig_hup = 0; cfg_load(); find_backlight();
			for (int i = 0; i < ndev; i++) if (!wants_device(devs[i].fd)) close_dev(i--);
			scan_devices(); leds_apply(1); logm("config reloaded");
		}
		if (t - last_scan >= 5000) { scan_devices(); last_scan = t; }
		if (t - last_house >= 500) {
			int b = idled_blanked(), nn = is_night();
			if (b != blanked) {
				blanked = b;
				if (b) for (int i = 0; i < C.nbtn; i++) C.btn[i].down = 0;   /* grabbed: no release comes */
				leds_apply(0);
				if (verbose) logm("screen %s", b ? "blank" : "awake");
			}
			if (nn != night_now) { night_now = nn; brightness_override_clear(); leds_apply(0); }
			/* every 5 s: re-apply the LEDs if something else changed them */
			if (t / 5000 != last_house / 5000) leds_apply(1);
			last_house = t;
		}
		timers(t);

		/* poll timeout: next button deadline, feedback end, housekeeping */
		long long next = t + 500;
		for (int i = 0; i < C.nbtn; i++) if (C.btn[i].down && C.btn[i].t_next < next) next = C.btn[i].t_next;
		for (int i = 0; i < NLED; i++) if (feedback_until[i] && feedback_until[i] < next) next = feedback_until[i];
		int to = next > t ? (int)(next - t) : 0;

		struct pollfd pfd[MAXDEV + 1]; int np = 0;
		for (int i = 0; i < ndev; i++) { pfd[np].fd = devs[i].fd; pfd[np].events = POLLIN; pfd[np++].revents = 0; }
		if (ctl >= 0) { pfd[np].fd = ctl; pfd[np].events = POLLIN; pfd[np++].revents = 0; }
		int n = poll(pfd, np, to);
		if (n < 0) { if (errno == EINTR) continue; logm("poll: %s", strerror(errno)); sleep(1); continue; }
		if (n == 0) continue;
		t = now_ms();
		if (ctl >= 0 && (pfd[np - 1].revents & POLLIN)) {
			static char cbuf[1024]; static size_t clen; ssize_t r;
			while ((r = read(ctl, cbuf + clen, sizeof cbuf - 1 - clen)) > 0) {
				clen += r; cbuf[clen] = 0;
				char *nl;
				while ((nl = strchr(cbuf, '\n'))) {
					*nl = 0; control(cbuf);
					memmove(cbuf, nl + 1, clen - (nl + 1 - cbuf) + 1); clen -= nl + 1 - cbuf;
				}
				if (clen >= sizeof cbuf - 1) clen = 0;
			}
		}
		for (int i = ndev - 1; i >= 0; i--) {
			if (pfd[i].revents & (POLLERR | POLLHUP | POLLNVAL)) { logm("lost %s", devs[i].path); close_dev(i); continue; }
			if (!(pfd[i].revents & POLLIN)) continue;
			struct input_event ev[64]; ssize_t r;
			while ((r = read(devs[i].fd, ev, sizeof ev)) > 0)
				for (size_t k = 0; k < (size_t)r / sizeof ev[0]; k++)
					if (ev[k].type == EV_KEY) key_event(ev[k].code, ev[k].value, t);
			if (r == 0 || (r < 0 && errno != EAGAIN && errno != EINTR)) { logm("lost %s", devs[i].path); close_dev(i); }
		}
	}
	unlink(ctlpath);
	logm("exit");
	return 0;
}
