/*
 * tsx-idled: screen blanking with wake-on-touch for the xx60 kiosk.
 *
 * Compositor independent: it watches every /dev/input/event* device itself.
 *  - After BLANK_TIMEOUT seconds without input it sets the backlight to 0 and
 *    grabs (EVIOCGRAB) all input devices, so the touch that wakes the screen
 *    does not also press a button on the dashboard.
 *  - On the first event while blank it restores the backlight, swallows the
 *    rest of that gesture (until no event for WAKE_SWALLOW_MS) and ungrabs.
 *  - Brightness follows a day/night schedule (BRIGHTNESS_DAY/NIGHT in
 *    backlight steps, NIGHT_START/NIGHT_END hours, local time), clamped to
 *    BACKLIGHT_MAX (the TSX panels: MP3309C 0..31, vendor cap 23, U-Boot 17).
 *  - KEY_POWER (the TSX power key, gpio-keys-polled) toggles blank/wake when
 *    POWER_KEY=blank.
 *  - On-screen keyboard toggle (OSK_GESTURE=threefinger|twofinger|off): a
 *    short tap with exactly three (two) fingers (all released within
 *    OSK_TAP_MS, moved less than 40 px) runs OSK_TOGGLE_CMD (default
 *    "/usr/local/bin/tsx-osk toggle"). Not while blank or swallowing.
 *    Default three: Chromium opens its context menu on a two-finger tap.
 *  - Signals: SIGUSR1 = wake now, SIGUSR2 = blank now, SIGHUP = reload config.
 *  - State is written to /run/tsx-idled.state ("on <level>" or "blank").
 *  - Every 5 s the level is re-applied if the schedule or someone else
 *    (drm panel enable on unblank, brightnessctl) changed it.
 *
 * Config: shell-style KEY=VALUE file (default /etc/kiosk.conf).
 * Env overrides for testing: TSX_INPUT_DIR, TSX_BACKLIGHT_DIR, TSX_STATE_FILE.
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
#include <sys/ioctl.h>
#include <sys/stat.h>
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
	/* prefer the first entry in name order for stable behaviour */
	char best[NAME_MAX + 1] = "";
	while ((e = readdir(d)))
		if (e->d_name[0] != '.' && (!best[0] || strcmp(e->d_name, best) < 0))
			snprintf(best, sizeof best, "%s", e->d_name);
	closedir(d);
	if (best[0]) snprintf(bldir, sizeof bldir, "%s/%s", base, best);
}

static int target_level(void)
{
	time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
	int h = tm.tm_hour, s = C.night_start, e = C.night_end, night;
	/* tsx-buttons brightness up/down: level override until the next
	 * day/night change (tsx-buttons removes the file then) */
	int o = read_int(ovrdir, "brightness");
	if (o > 0) return o;
	/* tsx-als : ambient light level while the file is fresh */
	{
		char p[PATH_MAX + 16]; struct stat st;
		snprintf(p, sizeof p, "%s/als-level", ovrdir);
		if (!stat(p, &st) && time(NULL) - st.st_mtime < 30 &&
		    (o = read_int(ovrdir, "als-level")) > 0)
			return o;
	}
	if (s == e) night = 0;
	else if (s < e) night = h >= s && h < e;
	else night = h >= s || h < e;
	return night ? C.night : C.day;
}

static void set_state(const char *s)
{
	FILE *f = fopen(statefile, "w");
	if (f) { fputs(s, f); fputc('\n', f); fclose(f); }
}

static int cur_level = -1;
static void backlight_on(void)
{
	int max, lvl = target_level();
	char st[64];
	if (!bldir[0]) find_backlight();
	max = bldir[0] ? read_int(bldir, "max_brightness") : -1;
	if (max <= 0) { if (verbose) logm("no backlight"); set_state("on none"); return; }
	if (C.bl_max > 0 && max > C.bl_max) max = C.bl_max;
	if (lvl > max) lvl = max;
	if (lvl < 1) lvl = 1;
	/* rewrite also when someone else changed it (drm/meson's panel enable
	 * restores 16 on unblank; brightnessctl); the config is authoritative */
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

/* Multitouch type B tracking for the OSK tap. Returns 1 when a tap with
 * exactly OSK_GESTURE fingers just ended. */
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
	sigemptyset(&sa.sa_mask);
	sigaction(SIGUSR1, &sa, NULL); sigaction(SIGUSR2, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL); sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
	signal(SIGCHLD, SIG_IGN);   /* OSK_TOGGLE_CMD children reap themselves */

	cfg_load(&C); find_backlight();
	logm("timeout %ds, day %d, night %d (%02d-%02d h), cap %d, backlight %s, osk gesture %s",
	     C.blank_timeout, C.day, C.night, C.night_start, C.night_end, C.bl_max, bldir[0] ? bldir : "none",
	     C.osk_gesture == 3 ? "threefinger" : C.osk_gesture == 2 ? "twofinger" : "off");
	backlight_on();

	int blanked = 0, swallowing = 0;
	long long last_input = now_ms(), last_scan = 0, last_sched = 0, swallow_until = 0;

	while (!sig_term) {
		long long t = now_ms();
		if (t - last_scan >= 5000) { scan_devices(blanked && C.swallow); last_scan = t; }
		if (sig_hup) {
			sig_hup = 0; cfg_load(&C); bldir[0] = 0; find_backlight(); cur_level = -1;
			if (!blanked) backlight_on();
			logm("config reloaded");
		}
		if (sig_blank) { sig_blank = 0; if (!blanked) { backlight_off(); blanked = 1; if (C.swallow) grab_all(1); } }
		if (sig_wake) { sig_wake = 0; last_input = t;
			        if (blanked) { blanked = 0; cur_level = -1; backlight_on(); grab_all(0); } }
		if (!blanked && C.blank_timeout > 0 && t - last_input >= (long long)C.blank_timeout * 1000) {
			backlight_off(); blanked = 1; if (C.swallow) grab_all(1);
		}
		if (!blanked && !swallowing && t - last_sched >= 5000) { backlight_on(); last_sched = t; }
		if (swallowing && t >= swallow_until) { swallowing = 0; grab_all(0); if (verbose) logm("ungrab"); }

		/* poll timeout: until the next deadline, at most 1 s */
		int to = 1000;
		if (!blanked && C.blank_timeout > 0) {
			long long left = last_input + (long long)C.blank_timeout * 1000 - t;
			if (left < to) to = left < 0 ? 0 : (int)left;
		}
		if (swallowing && swallow_until - t < to) to = swallow_until - t < 0 ? 0 : (int)(swallow_until - t);

		struct pollfd pfd[MAXDEV];
		for (int i = 0; i < ndev; i++) { pfd[i].fd = devs[i].fd; pfd[i].events = POLLIN; pfd[i].revents = 0; }
		int n = poll(pfd, ndev, to);
		if (n < 0) { if (errno == EINTR) continue; logm("poll: %s", strerror(errno)); sleep(1); continue; }
		if (n == 0) continue;
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
						continue;   /* release/repeat of the power key is no activity */
					}
					/* A key release is no activity either: tsx-buttons blanks on a
					 * front-key press (SIGUSR2); if that signal is handled before
					 * this loop reads the key's release, the release would wake the
					 * screen it just blanked (b race). Touch lifts still count
					 * through their ABS/MT events. */
					if (ev[k].type == EV_KEY && ev[k].value == 0) continue;
					got = 1;
				}
			}
			if (!raw && r == 0) { close_dev(i); continue; }
			if (r < 0 && errno != EAGAIN && errno != EINTR) { close_dev(i); continue; }
			if (!got) continue;
			last_input = t;
			if (power && C.power_key && !blanked && !swallowing) {
				backlight_off(); blanked = 1; if (C.swallow) grab_all(1);
				if (verbose) logm("power key: blank");
				continue;
			}
			if (blanked) {
				blanked = 0; cur_level = -1; backlight_on();
				if (C.swallow) { swallowing = 1; swallow_until = t + C.swallow_ms; }
				else grab_all(0);
				if (verbose) logm("wake");
			} else if (swallowing) {
				swallow_until = t + C.swallow_ms; /* extend until the gesture ends */
			} else if (osk && C.osk_gesture) {
				run_osk_cmd();
			}
		}
	}
	grab_all(0);
	backlight_on();
	logm("exit");
	return 0;
}
