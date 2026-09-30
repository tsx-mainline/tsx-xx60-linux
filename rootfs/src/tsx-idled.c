/*
 * tsx-idled: screen blanking with wake-on-touch for the xx60 kiosk.
 *
 * It does not depend on the compositor. It watches every /dev/input/event*
 * device itself.
 *  - After BLANK_TIMEOUT seconds without input, it grabs (EVIOCGRAB) all input
 *    devices, sets the backlight to 0 and then turns the display output off
 *    (DISPLAY_POWER_CMD with the argument "off"). The touch that wakes the
 *    screen then does not also press a button on the dashboard. With only the
 *    backlight off, the LCD keeps the last frame, and the frame shows in room
 *    light. With the output off, the glass shows nothing.
 *  - On the first event while the screen is blank, it turns the display
 *    output on (DISPLAY_POWER_CMD "on", the daemon waits for it), restores
 *    the backlight, swallows the rest of that gesture (until no event for
 *    WAKE_SWALLOW_MS) and ungrabs.
 *  - DISPLAY_POWER_CMD (default "/usr/local/bin/tsx-display-power", empty =
 *    backlight only) gets "on" or "off" as its last argument. The daemon waits
 *    for it DISPLAY_POWER_TIMEOUT_MS at most (default 3000). While the screen
 *    is blank, the daemon runs "off" again every 30 s: a compositor that
 *    starts during the blank (the nightly kiosk restart) turns its output on.
 *  - Brightness follows a day/night schedule (BRIGHTNESS_DAY/NIGHT in
 *    backlight steps, NIGHT_START/NIGHT_END hours, local time). BACKLIGHT_MAX
 *    limits it (the TSX panels: MP3309C 0..31, vendor cap 23, U-Boot 17).
 *  - KEY_POWER (the TSX power key, gpio-keys-polled) toggles blank and wake
 *    when POWER_KEY=blank.
 *  - On-screen keyboard toggle (OSK_GESTURE=threefinger|twofinger|off): a
 *    short tap with exactly three (or two) fingers runs OSK_TOGGLE_CMD
 *    (default "/usr/local/bin/tsx-osk toggle"). The fingers must all lift
 *    within OSK_TAP_MS and move less than 40 px. The tap does nothing while
 *    the screen is blank or the daemon swallows a gesture.
 *    The default is three fingers, because Chromium opens its context menu on
 *    a two-finger tap.
 *  - Signals: SIGUSR1 = wake now, SIGUSR2 = blank now, SIGHUP = reload config.
 *  - The daemon writes its state to /run/tsx-idled.state ("on <level>" or
 *    "blank").
 *  - Every 5 s, the daemon applies the level again if the schedule or someone
 *    else (drm panel enable on unblank, brightnessctl) changed it.
 *  - Boot hold: the daemon can start within the first minute after boot while
 *    the backlight is still lit (the U-Boot logo level, which the kernel
 *    keeps). Then it does not step the level to the day/night schedule until
 *    tsx-als has published its first level (als-level), for 15 s at most
 *    (TSX_BOOT_HOLD seconds overrides it, 0 = off). Meanwhile the state is
 *    "on <current>", so tsx-als ramps from what is on the glass. The level
 *    does not jump up to the schedule and back down to the ambient level
 *    while the boot splash shows.
 *
 * Runtime files in /run/tsx (TSX_RUN_DIR). The daemon watches them with
 * inotify, so a change applies at once (it only reads als-level, which changes
 * every second):
 *    brightness         absolute level (front keys "brightness N", the HA
 *                       Backlight number). It wins over everything below.
 *    als-level          tsx-als level while it is fresh (< 30 s). Otherwise
 *                       the day/night schedule, which is the "base" level.
 *    brightness-offset  signed steps added to the base (the local manual
 *                       setting: key-strip slide, quick-settings overlay).
 *                       The result is clamped to 1..BACKLIGHT_MAX.
 *    blank-timeout      seconds, replaces BLANK_TIMEOUT (tsx-config apply
 *                       writes it from panel.conf. The HA "Blank timeout")
 *  The daemon writes brightness.state ("level L", "base B", "offset O",
 *  "override V" (0 = none), "max M", "blank_timeout T") and last-input
 *  (epoch seconds of the last real input event, at most once per second).
 *
 * Config: shell-style KEY=VALUE file (default /etc/kiosk.conf).
 * Env overrides for testing: TSX_INPUT_DIR, TSX_BACKLIGHT_DIR, TSX_STATE_FILE,
 * TSX_RUN_DIR, TSX_DISPLAY_REPEAT_MS (the 30 s "off" repeat while blank).
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAXDEV 32

struct cfg {
	int blank_timeout;      /* s, 0 = never */
	int day, night;         /* backlight steps */
	int bl_max;             /* cap, <= max_brightness */
	int power_key;          /* 1 = KEY_POWER toggles blank */
	int night_start, night_end; /* hour 0-23; equal = no night */
	int swallow;            /* grab while blank */
	int swallow_ms;
	char backlight[PATH_MAX]; /* sysfs dir or "auto" */
	int osk_gesture;        /* fingers of the tap that runs osk_cmd, 0 = off */
	int osk_tap_ms;
	char osk_cmd[512];
	char disp_cmd[512];     /* display output on/off command, "" = none */
	int disp_timeout_ms;
};

static struct cfg C;
static const char *cfgfile = "/etc/kiosk.conf";
static const char *indir = "/dev/input";
static const char *statefile = "/run/tsx-idled.state";
static const char *ovrdir = "/run/tsx";   /* brightness override (tsx-buttons) */
static char bldir[PATH_MAX];
static int verbose;
static volatile sig_atomic_t sig_wake, sig_blank, sig_hup, sig_term;

#define MAXSLOT 10
struct dev {
	int fd; char path[PATH_MAX]; int grabbed;
	/* multitouch state for the OSK tap */
	int slot, id[MAXSLOT], x[MAXSLOT], y[MAXSLOT], x0[MAXSLOT], y0[MAXSLOT];
	int maxc, moved; long long t0;
};
static struct dev devs[MAXDEV];
static int ndev;

static void logm(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt);
	fprintf(stderr, "tsx-idled: "); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
	va_end(ap);
}

static long long now_ms(void)
{
	struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void cfg_defaults(struct cfg *c)
{
	c->blank_timeout = 300; c->day = 17; c->night = 8; c->bl_max = 23; c->power_key = 1;
	c->night_start = 22; c->night_end = 7; c->swallow = 1; c->swallow_ms = 700;
	strcpy(c->backlight, "auto");
	c->osk_gesture = 3; c->osk_tap_ms = 500;
	strcpy(c->osk_cmd, "/usr/local/bin/tsx-osk toggle");
	strcpy(c->disp_cmd, "/usr/local/bin/tsx-display-power");
	c->disp_timeout_ms = 3000;
}

static void cfg_load(struct cfg *c)
{
	FILE *f = fopen(cfgfile, "r");
	char line[512];
	cfg_defaults(c);
	if (!f) { logm("no %s, using defaults", cfgfile); return; }
	while (fgets(line, sizeof line, f)) {
		char *p = line, *eq, *v, *e;
		while (isspace((unsigned char)*p)) p++;
		if (*p == '#' || !(eq = strchr(p, '='))) continue;
		*eq = 0; v = eq + 1;
		if ((e = strchr(v, '#')) && (e == v || isspace((unsigned char)e[-1]))) *e = 0;
		for (e = v + strlen(v); e > v && isspace((unsigned char)e[-1]); ) *--e = 0;
		if ((*v == '"' || *v == '\'') && e > v + 1 && e[-1] == *v) { v++; e[-1] = 0; }
#define I(k, f) if (!strcmp(p, k)) c->f = atoi(v)
		I("BLANK_TIMEOUT", blank_timeout); I("BRIGHTNESS_DAY", day);
		I("BRIGHTNESS_NIGHT", night); I("NIGHT_START", night_start);
		I("NIGHT_END", night_end); I("SWALLOW_WAKE_TOUCH", swallow);
		I("WAKE_SWALLOW_MS", swallow_ms); I("BACKLIGHT_MAX", bl_max);
		if (!strcmp(p, "POWER_KEY")) c->power_key = !strcmp(v, "blank");
		if (!strcmp(p, "BACKLIGHT") && *v) snprintf(c->backlight, sizeof c->backlight, "%s", v);
		if (!strcmp(p, "OSK_GESTURE")) c->osk_gesture = !strcmp(v, "threefinger") ? 3 : !strcmp(v, "twofinger") ? 2 : 0;
		I("OSK_TAP_MS", osk_tap_ms);
		if (!strcmp(p, "OSK_TOGGLE_CMD") && *v) snprintf(c->osk_cmd, sizeof c->osk_cmd, "%s", v);
		/* An empty value turns the display power control off. */
		if (!strcmp(p, "DISPLAY_POWER_CMD")) snprintf(c->disp_cmd, sizeof c->disp_cmd, "%s", v);
		I("DISPLAY_POWER_TIMEOUT_MS", disp_timeout_ms);
#undef I
	}
	fclose(f);
}

static int read_int(const char *dir, const char *name)
{
	char p[PATH_MAX + 64]; FILE *f; int v = -1;
	snprintf(p, sizeof p, "%s/%s", dir, name);
	if ((f = fopen(p, "r"))) { if (fscanf(f, "%d", &v) != 1) v = -1; fclose(f); }
	return v;
}

/* Read a signed value. Return 0 if the read worked. Return -1 if the value is
 * missing or garbage (a value of -1 is not an error). */
static int read_sint(const char *dir, const char *name, int *out)
{
	char p[PATH_MAX + 64]; FILE *f; int v, ok;
	snprintf(p, sizeof p, "%s/%s", dir, name);
	if (!(f = fopen(p, "r"))) return -1;
	ok = fscanf(f, "%d", &v) == 1;
	fclose(f);
	if (!ok) return -1;
	*out = v;
	return 0;
}

static int write_int(const char *dir, const char *name, int v)
{
	char p[PATH_MAX + 64]; FILE *f;
	snprintf(p, sizeof p, "%s/%s", dir, name);
	if (!(f = fopen(p, "w"))) return -1;
	fprintf(f, "%d\n", v);
	return fclose(f);
}

static void find_backlight(void)
{
	const char *base = getenv("TSX_BACKLIGHT_DIR");
	DIR *d; struct dirent *e;
	bldir[0] = 0;
	if (strcmp(C.backlight, "auto")) {
		snprintf(bldir, sizeof bldir, "%s", C.backlight);
		return;
	}
	if (!base) base = "/sys/class/backlight";
	if (!(d = opendir(base))) return;
	/* Prefer the first entry in name order, so the choice stays stable. */
	char best[NAME_MAX + 1] = "";
	while ((e = readdir(d)))
		if (e->d_name[0] != '.' && (!best[0] || strcmp(e->d_name, best) < 0))
			snprintf(best, sizeof best, "%s", e->d_name);
	closedir(d);
	if (best[0]) snprintf(bldir, sizeof bldir, "%s/%s", base, best);
}

/* The level without any manual setting. It is the tsx-als level while its
 * file is fresh. Otherwise it is the day/night schedule. */
static int base_level(void)
{
	time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
	int h = tm.tm_hour, s = C.night_start, e = C.night_end, night, o;
	char p[PATH_MAX + 16]; struct stat st;
	snprintf(p, sizeof p, "%s/als-level", ovrdir);
	if (!stat(p, &st) && time(NULL) - st.st_mtime < 30 &&
	    (o = read_int(ovrdir, "als-level")) > 0)
		return o;
	if (s == e) night = 0;
	else if (s < e) night = h >= s && h < e;
	else night = h >= s || h < e;
	return night ? C.night : C.day;
}

static int st_base, st_offset, st_override, st_max = -1;

static int target_level(void)
{
	int off = 0;
	/* Absolute level (front keys "brightness N", HA Backlight number). It
	 * holds until the next day/night change (tsx-buttons then removes the
	 * file) or until "auto brightness" turns on. */
	st_override = read_int(ovrdir, "brightness");
	if (st_override < 0) st_override = 0;
	st_base = base_level();
	/* The local manual setting: an offset on top of ALS or the schedule. */
	if (read_sint(ovrdir, "brightness-offset", &off) || off < -64 || off > 64) off = 0;
	st_offset = off;
	return st_override > 0 ? st_override : st_base + off;
}

static void set_state(const char *s)
{
	FILE *f = fopen(statefile, "w");
	if (f) { fputs(s, f); fputc('\n', f); fclose(f); }
}

/* Write a small /run/tsx file atomically. A reader never sees a half-written file. */
static void write_run_file(const char *name, const char *text)
{
	char p[PATH_MAX + 64], tmp[PATH_MAX + 80]; FILE *f;
	snprintf(p, sizeof p, "%s/%s", ovrdir, name);
	snprintf(tmp, sizeof tmp, "%s.tmp", p);
	if (!(f = fopen(tmp, "w"))) return;
	fputs(text, f);
	if (fclose(f) == 0) rename(tmp, p);
	else unlink(tmp);
}

static int eff_timeout;   /* BLANK_TIMEOUT, or the runtime file */

/* brightness.state for the overlay, tsx-buttons and Home Assistant. It shows
 * how the level came about. The daemon rewrites it only when something in it
 * changed. */
static void write_bstate(int lvl)
{
	static char last[160];
	char b[160];
	int base = st_base;
	if (st_max > 0 && base > st_max) base = st_max;
	if (base < 1) base = 1;
	snprintf(b, sizeof b, "level %d\nbase %d\noffset %d\noverride %d\nmax %d\nblank_timeout %d\n",
		 lvl, base, st_offset, st_override, st_max, eff_timeout);
	if (!strcmp(b, last)) return;
	snprintf(last, sizeof last, "%s", b);
	write_run_file("brightness.state", b);
}

/* True if tsx-als wrote als-level within the last 30 s (wall clock, as in base_level). */
static int als_fresh(void)
{
	char p[PATH_MAX + 16]; struct stat st;
	snprintf(p, sizeof p, "%s/als-level", ovrdir);
	return !stat(p, &st) && time(NULL) - st.st_mtime < 30 && read_int(ovrdir, "als-level") > 0;
}

static int cur_level = -1;
static long long hold_until;   /* boot hold (see the header), 0 = none */
static void backlight_on(void)
{
	int max, lvl = target_level();
	char st[64];
	if (!bldir[0]) find_backlight();
	max = bldir[0] ? read_int(bldir, "max_brightness") : -1;
	if (max <= 0) { if (verbose) logm("no backlight"); set_state("on none"); return; }
	if (hold_until) {
		int cur = read_int(bldir, "brightness");
		if (now_ms() < hold_until && !als_fresh() && read_int(ovrdir, "brightness") <= 0 && cur > 0) {
			snprintf(st, sizeof st, "on %d", cur);
			set_state(st);
			return;
		}
		hold_until = 0;
		if (verbose) logm("boot hold over (%s)", als_fresh() ? "als-level" : "timeout");
	}
	if (C.bl_max > 0 && max > C.bl_max) max = C.bl_max;
	st_max = max;
	if (lvl > max) lvl = max;
	if (lvl < 1) lvl = 1;
	write_bstate(lvl);
	/* Write the level again also when someone else changed it (the panel
	 * enable of drm/meson restores 16 on unblank, and so does brightnessctl).
	 * The config is authoritative. */
	if (lvl != cur_level || read_int(bldir, "brightness") != lvl) {
		write_int(bldir, "bl_power", 0);
		if (write_int(bldir, "brightness", lvl)) logm("write brightness failed: %s", strerror(errno));
		else if (verbose) logm("backlight %d (cap %d)", lvl, max);
		cur_level = lvl;
	}
	snprintf(st, sizeof st, "on %d", lvl);
	set_state(st);
}

static void backlight_off(void)
{
	if (!bldir[0]) find_backlight();
	if (bldir[0]) {
		write_int(bldir, "brightness", 0);
		write_int(bldir, "bl_power", 4); /* FB_BLANK_POWERDOWN, ignored if absent */
	}
	cur_level = 0;
	if (verbose) logm("blank");
	set_state("blank");
}

/* Run DISPLAY_POWER_CMD with "on" or "off" and wait for it (at most
 * DISPLAY_POWER_TIMEOUT_MS). The wake path turns the output on before the
 * backlight, so the order matters, and the daemon waits. If the command does
 * not end in time, the daemon continues and the main loop reaps the child
 * later. The daemon logs a failure only when the result changes, because it
 * repeats "off" while the screen is blank. */
static void display_power(int on)
{
	static int last_rc = 0;
	char cmd[sizeof C.disp_cmd + 8];
	long long t0 = now_ms(), end;
	int status, rc = -1;
	pid_t pid;
	if (!C.disp_cmd[0]) return;
	snprintf(cmd, sizeof cmd, "%s %s", C.disp_cmd, on ? "on" : "off");
	if ((pid = fork()) == 0) {
		execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
		_exit(127);
	}
	if (pid < 0) { logm("fork: %s", strerror(errno)); return; }
	end = t0 + (C.disp_timeout_ms > 0 ? C.disp_timeout_ms : 3000);
	for (;;) {
		pid_t r = waitpid(pid, &status, WNOHANG);
		if (r == pid) { rc = WIFEXITED(status) ? WEXITSTATUS(status) : 128; break; }
		if (r < 0 && errno != EINTR) break;
		if (now_ms() >= end) { logm("%s: no result after %d ms, continuing", cmd, (int)(now_ms() - t0)); rc = 124; break; }
		struct timespec ts = { 0, 5 * 1000000 };
		nanosleep(&ts, NULL);
	}
	if (rc != last_rc) logm("%s: exit %d", cmd, rc);
	else if (verbose) logm("%s: exit %d after %lld ms", cmd, rc, now_ms() - t0);
	last_rc = rc;
}

static void grab_all(int on);

/* Blank: grab the input first (the wake touch must not reach the dashboard),
 * then the backlight off, then the display output off. */
static void screen_off(void)
{
	if (C.swallow) grab_all(1);
	backlight_off();
	display_power(0);
}

/* Wake: the display output on first, then the backlight. The panel then
 * lights up with the current frame, not with a black or stale one. */
static void screen_on(void)
{
	display_power(1);
	cur_level = -1;
	backlight_on();
}

static void grab_all(int on)
{
	for (int i = 0; i < ndev; i++) {
		if (devs[i].grabbed == on) continue;
		if (ioctl(devs[i].fd, EVIOCGRAB, (void *)(long)on) == 0 || !on)
			devs[i].grabbed = on;
	}
}

static void close_dev(int i)
{
	close(devs[i].fd);
	devs[i] = devs[--ndev];
}

static void scan_devices(int want_grab)
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
		memset(&devs[ndev], 0, sizeof devs[ndev]);
		for (int k = 0; k < MAXSLOT; k++) devs[ndev].id[k] = -1;
		devs[ndev].fd = fd; devs[ndev].grabbed = 0;
		snprintf(devs[ndev].path, sizeof devs[ndev].path, "%s", p);
		if (verbose) logm("watching %s", p);
		ndev++;
		if (want_grab) grab_all(1);
	}
	closedir(d);
}

static void run_osk_cmd(void)
{
	pid_t pid;
	if (!C.osk_cmd[0]) return;
	logm("%d-finger tap: %s", C.osk_gesture, C.osk_cmd);
	if ((pid = fork()) == 0) {
		setsid();
		execl("/bin/sh", "sh", "-c", C.osk_cmd, (char *)NULL);
		_exit(127);
	}
	if (pid < 0) logm("fork: %s", strerror(errno));
}

/* Multitouch type B tracking for the OSK tap. Return 1 when a tap with
 * exactly OSK_GESTURE fingers has just ended. */
static int mt_event(struct dev *d, const struct input_event *e, long long t)
{
	int s = d->slot, n = 0, fired = 0;
	if (e->type != EV_ABS && e->type != EV_SYN) return 0;
	if (e->type == EV_ABS) {
		switch (e->code) {
		case ABS_MT_SLOT: if (e->value >= 0 && e->value < MAXSLOT) d->slot = e->value; return 0;
		case ABS_MT_POSITION_X: if (s < MAXSLOT) d->x[s] = e->value; return 0;
		case ABS_MT_POSITION_Y: if (s < MAXSLOT) d->y[s] = e->value; return 0;
		case ABS_MT_TRACKING_ID:
			if (s >= MAXSLOT) return 0;
			if (e->value >= 0 && d->id[s] < 0) d->x0[s] = d->y0[s] = -1;
			d->id[s] = e->value;
			return 0;
		default: return 0;
		}
	}
	if (e->code != SYN_REPORT) return 0;
	for (int k = 0; k < MAXSLOT; k++) {
		if (d->id[k] < 0) continue;
		n++;
		if (d->x0[k] < 0) { d->x0[k] = d->x[k]; d->y0[k] = d->y[k]; }
		else if (abs(d->x[k] - d->x0[k]) > 40 || abs(d->y[k] - d->y0[k]) > 40) d->moved = 1;
	}
	if (n > 0 && d->maxc == 0) { d->t0 = t; d->moved = 0; }
	if (n > d->maxc) d->maxc = n;
	if (n == 0 && d->maxc > 0) {
		fired = C.osk_gesture && d->maxc == C.osk_gesture && !d->moved && t - d->t0 <= C.osk_tap_ms;
		d->maxc = 0;
	}
	return fired;
}

/* BLANK_TIMEOUT. /run/tsx/blank-timeout replaces it while that file exists. */
static void load_timeout(int quiet)
{
	int v, old = eff_timeout, src_file = 0;
	if (read_sint(ovrdir, "blank-timeout", &v) == 0 && v >= 0) { eff_timeout = v; src_file = 1; }
	else eff_timeout = C.blank_timeout;
	if (!quiet && eff_timeout != old)
		logm("blank timeout %ds (%s)", eff_timeout, src_file ? "runtime override" : "BLANK_TIMEOUT");
}

/* last-input: epoch seconds of the last real input, used for "touched recently". */
static void note_input(void)
{
	static time_t written;
	time_t s = time(NULL); char b[32];
	if (s == written) return;
	written = s;
	snprintf(b, sizeof b, "%lld\n", (long long)s);
	write_run_file("last-input", b);
}

static int ino_fd = -1;
static void watch_rundir(void)
{
	mkdir(ovrdir, 0755);
	ino_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	if (ino_fd < 0) { logm("inotify: %s (runtime files apply within 5 s)", strerror(errno)); return; }
	if (inotify_add_watch(ino_fd, ovrdir, IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_DELETE) < 0) {
		logm("inotify %s: %s (runtime files apply within 5 s)", ovrdir, strerror(errno));
		close(ino_fd); ino_fd = -1;
	}
}

/* Return 1 if a brightness input changed, or 2 if the blank timeout file
 * changed. The 5 s re-apply handles als-level. The file changes every second,
 * and tsx-als ramps the backlight toward it itself. */
static int read_inotify(void)
{
	char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
	ssize_t n; int m = 0;
	while ((n = read(ino_fd, buf, sizeof buf)) > 0)
		for (char *p = buf; p < buf + n; ) {
			struct inotify_event *e = (struct inotify_event *)p;
			if (e->len) {
				if (!strcmp(e->name, "brightness") || !strcmp(e->name, "brightness-offset")) m |= 1;
				else if (!strcmp(e->name, "blank-timeout")) m |= 2;
			}
			p += sizeof *e + e->len;
		}
	return m;
}

static void on_sig(int s)
{
	if (s == SIGUSR1) sig_wake = 1;
	else if (s == SIGUSR2) sig_blank = 1;
	else if (s == SIGHUP) sig_hup = 1;
	else sig_term = 1;
}

int main(int argc, char **argv)
{
	int opt;
	struct sigaction sa = { .sa_handler = on_sig };
	while ((opt = getopt(argc, argv, "c:v")) != -1) {
		if (opt == 'c') cfgfile = optarg;
		else if (opt == 'v') verbose = 1;
		else { fprintf(stderr, "usage: %s [-c config] [-v]\n", argv[0]); return 2; }
	}
	if (getenv("TSX_INPUT_DIR")) indir = getenv("TSX_INPUT_DIR");
	if (getenv("TSX_STATE_FILE")) statefile = getenv("TSX_STATE_FILE");
	if (getenv("TSX_RUN_DIR")) ovrdir = getenv("TSX_RUN_DIR");
	long long off_repeat = getenv("TSX_DISPLAY_REPEAT_MS") ? atoll(getenv("TSX_DISPLAY_REPEAT_MS")) : 30000;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGUSR1, &sa, NULL); sigaction(SIGUSR2, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL); sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
	/* SIGCHLD stays at the default: display_power() waits for its child. The
	 * main loop reaps the OSK_TOGGLE_CMD children (and a display command that
	 * did not end in time). */
	signal(SIGCHLD, SIG_DFL);

	cfg_load(&C); find_backlight();
	{
		/* boot hold (see the header) */
		double up = 1e9; FILE *f = fopen("/proc/uptime", "r");
		const char *e = getenv("TSX_BOOT_HOLD");
		int secs = 15;
		if (f) { if (fscanf(f, "%lf", &up) != 1) up = 1e9; fclose(f); }
		if (e) secs = atoi(e);
		else if (up >= 60) secs = 0;
		if (secs > 0 && bldir[0] && read_int(bldir, "brightness") > 0 && read_int(bldir, "bl_power") <= 0)
			hold_until = now_ms() + secs * 1000LL;
	}
	watch_rundir();
	load_timeout(1);
	logm("timeout %ds%s, day %d, night %d (%02d-%02d h), cap %d, backlight %s, osk gesture %s",
	     eff_timeout, eff_timeout != C.blank_timeout ? " (runtime override)" : "",
	     C.day, C.night, C.night_start, C.night_end, C.bl_max, bldir[0] ? bldir : "none",
	     C.osk_gesture == 3 ? "threefinger" : C.osk_gesture == 2 ? "twofinger" : "off");
	/* A previous instance can have stopped while the output was off. */
	display_power(1);
	backlight_on();

	int blanked = 0, swallowing = 0;
	long long last_input = now_ms(), last_scan = 0, last_sched = 0, swallow_until = 0, last_off = 0;

	while (!sig_term) {
		long long t = now_ms();
		while (waitpid(-1, NULL, WNOHANG) > 0) ;   /* OSK_TOGGLE_CMD children */
		if (t - last_scan >= 5000) { scan_devices(blanked && C.swallow); last_scan = t; }
		if (sig_hup) {
			sig_hup = 0; cfg_load(&C); load_timeout(0); bldir[0] = 0; find_backlight(); cur_level = -1;
			if (!blanked) backlight_on();
			logm("config reloaded");
		}
		if (sig_blank) { sig_blank = 0; if (!blanked) { screen_off(); blanked = 1; last_off = t; } }
		if (sig_wake) { sig_wake = 0; last_input = t;
			        if (blanked) { blanked = 0; screen_on(); grab_all(0); } }
		if (!blanked && eff_timeout > 0 && t - last_input >= (long long)eff_timeout * 1000) {
			screen_off(); blanked = 1; last_off = t;
		}
		/* A compositor that started during the blank has its output on. */
		if (blanked && off_repeat > 0 && t - last_off >= off_repeat) { display_power(0); last_off = t; }
		if (!blanked && !swallowing && t - last_sched >= 5000) { backlight_on(); last_sched = t; }
		if (swallowing && t >= swallow_until) { swallowing = 0; grab_all(0); if (verbose) logm("ungrab"); }

		/* The poll timeout runs until the next deadline, 1 s at most. */
		int to = 1000;
		if (!blanked && eff_timeout > 0) {
			long long left = last_input + (long long)eff_timeout * 1000 - t;
			if (left < to) to = left < 0 ? 0 : (int)left;
		}
		if (swallowing && swallow_until - t < to) to = swallow_until - t < 0 ? 0 : (int)(swallow_until - t);

		struct pollfd pfd[MAXDEV + 1];
		int np = ndev;
		for (int i = 0; i < ndev; i++) { pfd[i].fd = devs[i].fd; pfd[i].events = POLLIN; pfd[i].revents = 0; }
		if (ino_fd >= 0) { pfd[np].fd = ino_fd; pfd[np].events = POLLIN; pfd[np++].revents = 0; }
		int n = poll(pfd, np, to);
		if (n < 0) { if (errno == EINTR) continue; logm("poll: %s", strerror(errno)); sleep(1); continue; }
		if (n == 0) continue;
		if (ino_fd >= 0 && (pfd[ndev].revents & POLLIN)) {
			int m = read_inotify();
			if (m & 2) load_timeout(0);
			/* A manual level, offset or timeout change applies now, not at
			 * the next 5 s tick (key-strip slide, overlay slider). */
			if (m && !blanked && !swallowing) backlight_on();
		}
		t = now_ms();
		for (int i = ndev - 1; i >= 0; i--) {
			if (pfd[i].revents & (POLLERR | POLLHUP | POLLNVAL)) {
				if (verbose) logm("lost %s", devs[i].path);
				close_dev(i); continue;
			}
			if (!(pfd[i].revents & POLLIN)) continue;
			struct input_event ev[64]; ssize_t r;
			int got = 0, power = 0, raw = 0, osk = 0;
			while ((r = read(devs[i].fd, ev, sizeof ev)) > 0) {
				raw = 1;
				for (size_t k = 0; k < (size_t)r / sizeof ev[0]; k++) {
					if (mt_event(&devs[i], &ev[k], t)) osk = 1;
					if (ev[k].type == EV_SYN) continue;
					if (ev[k].type == EV_KEY && ev[k].code == KEY_POWER) {
						if (ev[k].value == 1) { power = 1; got = 1; }
						continue;   /* a release or repeat of the power key is no activity */
					}
					/* A key release is no activity either. tsx-buttons blanks the
					 * screen on a front-key press (SIGUSR2). If the daemon handles
					 * that signal before this loop reads the release of the key,
					 * the release would wake the screen that it just blanked (a
					 * race). Touch lifts still count through their ABS/MT events. */
					if (ev[k].type == EV_KEY && ev[k].value == 0) continue;
					got = 1;
				}
			}
			if (!raw && r == 0) { close_dev(i); continue; }
			if (r < 0 && errno != EAGAIN && errno != EINTR) { close_dev(i); continue; }
			if (!got) continue;
			last_input = t;
			note_input();
			if (power && C.power_key && !blanked && !swallowing) {
				screen_off(); blanked = 1; last_off = t;
				if (verbose) logm("power key: blank");
				continue;
			}
			if (blanked) {
				blanked = 0; screen_on();
				/* The swallow time starts when the picture is back. */
				if (C.swallow) { swallowing = 1; swallow_until = now_ms() + C.swallow_ms; }
				else grab_all(0);
				if (verbose) logm("wake");
			} else if (swallowing) {
				swallow_until = t + C.swallow_ms; /* extend the swallow until the gesture ends */
			} else if (osk && C.osk_gesture) {
				run_osk_cmd();
			}
		}
	}
	grab_all(0);
	if (blanked) display_power(1);
	cur_level = -1;
	backlight_on();
	logm("exit");
	return 0;
}
