/*
 * tsx-overlay: local quick settings for the xx60 kiosk (sway session only).
 *
 * A wlr-layer-shell surface on the OVERLAY layer at the right edge of the
 * screen, next to the front-key strip. In landscape it sits at the right
 * edge. When the panel hangs in portrait, it stays at the right edge, at most
 * as high as on the 10-inch landscape panel, and centered
 * (tsx-overlay-layout.h). The surface stays hidden (no surface at all) until
 * tsx-buttons asks for it over /run/tsx/overlay.ctl:
 *   slider   compact brightness bar, shown while a finger slides along the
 *            key strip. It hides OVERLAY_SLIDER_MS after the last step.
 *   full     brightness slider, Auto brightness, Screen off, Reload page and
 *            Close. It hides OVERLAY_FULL_MS after the last touch on it.
 *   hide, toggle
 * Keyboard interactivity is NONE. The overlay never takes the keyboard focus
 * from Chromium, so the on-screen keyboard keeps working. Touches outside the
 * surface still go to the page.
 *
 * The overlay only shows state (/run/tsx/brightness.state from tsx-idled and
 * /run/tsx/als.state from tsx-als). It hands every action to tsx-panelctl
 * (FIFO /run/tsx/panelctl, group kiosk, a fixed command list):
 *   brightness-offset N   the slider. The local manual setting is an offset
 *                         on top of ALS or the day/night schedule.
 *                         The slider runs from the floor (the "min" line of
 *                         brightness.state) to the top level. On a wide
 *                         range, the position maps to the level with a
 *                         square (tsx-level.h), so the dark end has finer
 *                         steps. The label shows the level as a percent of
 *                         the top level.
 *   als auto on|off
 *   blank on
 *   reload-page
 *   setup                 brings the on-panel setup page back up for about
 *                         15 minutes, even on an already-configured panel
 *                         (docs/rootfs.md "Setup page").
 * It runs as the kiosk user, never as root.
 *
 * Why C and cairo on wl_shm: the process stays resident, so the slider appears
 * on the first slide step. A GTK or Python client needs seconds to start on
 * this CPU and 40+ MB to stay resident. Here the idle cost is one sleeping
 * process of a few MB and no wakeups while the overlay is hidden. Touch and
 * pointer input both work (pointer: a mouse, or a virtual pointer in tests).
 *
 * Env (tests / tuning): TSX_RUN_DIR (/run/tsx), OVERLAY_SLIDER_MS (1500),
 * OVERLAY_FULL_MS (8000), TSX_OVERLAY_VERBOSE=1.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <cairo.h>
#include <wayland-client.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "tsx-overlay-layout.h"
#include "tsx-level.h"

enum mode { HIDDEN, SLIDER, FULL };

struct buffer { struct wl_buffer *wb; void *data; size_t size; int busy, w, h; cairo_surface_t *cs; };

static struct wl_display *dpy;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_touch *touch;
static struct wl_pointer *pointer;
static struct zwlr_layer_shell_v1 *layer_shell;
static struct wl_surface *surface;
static struct zwlr_layer_surface_v1 *layer;
static struct buffer bufs[2];

static const char *rundir = "/run/tsx";
static char ctlpath[PATH_MAX], panelctl[PATH_MAX], bstate[PATH_MAX], astate[PATH_MAX];
static int ctl_fd = -1, verbose, slider_ms = 1500, full_ms = 8000;
static volatile sig_atomic_t sig_term;

static enum mode mode = HIDDEN, want_mode = HIDDEN;
static int configured, surf_w, surf_h;
static int cur_mv, out_h;                /* the top and bottom margin of the surface, and the output height */
static long long hide_at;

/* the state on show */
static int level = -1, base = -1, offset, override, maxlvl = 23, minlvl = 1, als_auto = -1;
static int drag_level = -1;              /* level under the finger while dragging */
static long long drag_hold;              /* ...shown until tsx-idled reports it (or until this time) */
static int pressed = B_NONE, press_inside, touch_id = -1, ptr_down;
static double ptr_x, ptr_y;

/*
 * Layout (surface coordinates, scale 1, see tsx-overlay-layout.h). The surface
 * spans the output height minus a top and a bottom margin, so it fits either
 * panel: 1280x800 (10-inch: slider 600, full 720 px high) and 1024x600
 * (7-inch: slider 400, full 520). On a portrait output the margins grow, so
 * the surface is no higher than that.
 */
static struct rect r_track, r_btn[NBTN];

static void logm(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt);
	fprintf(stderr, "tsx-overlay: "); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
	va_end(ap);
}

static long long now_ms(void)
{
	struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int in_rect(const struct rect *r, double x, double y)
{
	return x >= r->x && x < r->x + r->w && y >= r->y && y < r->y + r->h;
}

/* ---- state files ---------------------------------------------------------- */
static int field(const char *path, const char *key, char *out, size_t n)
{
	FILE *f = fopen(path, "r"); char line[128]; size_t kl = strlen(key); int ok = -1;
	if (!f) return -1;
	while (fgets(line, sizeof line, f))
		if (!strncmp(line, key, kl) && line[kl] == ' ') {
			line[strcspn(line, "\n")] = 0;
			snprintf(out, n, "%s", line + kl + 1); ok = 0; break;
		}
	fclose(f);
	return ok;
}

static int ifield(const char *path, const char *key, int def)
{
	char b[32];
	return field(path, key, b, sizeof b) ? def : atoi(b);
}

/* Return 1 if anything shown changed. */
static int read_state(void)
{
	char b[32];
	int l = ifield(bstate, "level", -1), ba = ifield(bstate, "base", -1), of = ifield(bstate, "offset", 0);
	int ov = ifield(bstate, "override", 0), mx = ifield(bstate, "max", 23), mn = ifield(bstate, "min", 1), a = -1;
	if (!field(astate, "auto", b, sizeof b)) a = !strcmp(b, "on");
	if (mx < 2) mx = 23;
	if (mn < 1 || mn >= mx) mn = 1;
	int ch = l != level || ba != base || of != offset || ov != override || mx != maxlvl || mn != minlvl || a != als_auto;
	level = l; base = ba; offset = of; override = ov; maxlvl = mx; minlvl = mn; als_auto = a;
	return ch;
}

/* ---- actions (tsx-panelctl) ------------------------------------------------ */
static void panelctl_send(const char *fmt, ...)
{
	char line[96]; va_list ap; int fd;
	va_start(ap, fmt); vsnprintf(line, sizeof line - 1, fmt, ap); va_end(ap);
	strcat(line, "\n");
	if ((fd = open(panelctl, O_WRONLY | O_NONBLOCK | O_CLOEXEC)) < 0) {
		logm("tsx-panelctl not listening (%s): %s", panelctl, strerror(errno)); return;
	}
	if (write(fd, line, strlen(line)) < 0) logm("write %s: %s", panelctl, strerror(errno));
	close(fd);
	if (verbose) logm("-> panelctl: %s", line);
}

static void set_level(int l)
{
	if (l < minlvl) l = minlvl;     /* the floor: the slider never blanks the screen */
	if (l > maxlvl) l = maxlvl;
	if (l == drag_level) return;
	drag_level = l;
	/* The offset is relative to the base of tsx-idled (ALS or schedule).
	 * Without a base (an old tsx-idled), the current level replaces it. */
	int b = base > 0 ? base : (level > 0 ? level - offset : l);
	panelctl_send("brightness-offset %d", overlay_offset(l, b, maxlvl));
}

/* ---- drawing ---------------------------------------------------------------- */
static void rounded(cairo_t *c, double x, double y, double w, double h, double r)
{
	cairo_new_sub_path(c);
	cairo_arc(c, x + w - r, y + r, r, -M_PI / 2, 0);
	cairo_arc(c, x + w - r, y + h - r, r, 0, M_PI / 2);
	cairo_arc(c, x + r, y + h - r, r, M_PI / 2, M_PI);
	cairo_arc(c, x + r, y + r, r, M_PI, 3 * M_PI / 2);
	cairo_close_path(c);
}

static void text_center(cairo_t *c, const char *s, double cx, double cy, double size, int bold)
{
	cairo_text_extents_t te;
	cairo_select_font_face(c, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL, bold ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL);
	cairo_set_font_size(c, size);
	cairo_text_extents(c, s, &te);
	cairo_move_to(c, cx - te.width / 2 - te.x_bearing, cy - te.height / 2 - te.y_bearing);
	cairo_show_text(c, s);
}

static void sun(cairo_t *c, double cx, double cy, double r)
{
	cairo_arc(c, cx, cy, r * 0.45, 0, 2 * M_PI);
	cairo_fill(c);
	cairo_set_line_width(c, r * 0.14);
	cairo_set_line_cap(c, CAIRO_LINE_CAP_ROUND);
	for (int i = 0; i < 8; i++) {
		double a = i * M_PI / 4;
		cairo_move_to(c, cx + cos(a) * r * 0.68, cy + sin(a) * r * 0.68);
		cairo_line_to(c, cx + cos(a) * r, cy + sin(a) * r);
	}
	cairo_stroke(c);
}

static void layout(void)
{
	overlay_layout(mode != SLIDER, surf_h, &r_track, r_btn);
}

static void draw(cairo_t *c, int w, int h)
{
	int shown = drag_level > 0 ? drag_level : level;
	char s[32];
	cairo_set_operator(c, CAIRO_OPERATOR_SOURCE);
	cairo_set_source_rgba(c, 0, 0, 0, 0);
	cairo_paint(c);
	cairo_set_operator(c, CAIRO_OPERATOR_OVER);
	rounded(c, 1, 1, w - 2, h - 2, 28);
	cairo_set_source_rgba(c, 0.08, 0.09, 0.11, 0.95);
	cairo_fill_preserve(c);
	cairo_set_source_rgba(c, 1, 1, 1, 0.15);
	cairo_set_line_width(c, 2);
	cairo_stroke(c);

	/* brightness slider */
	struct rect t = r_track;
	double cx = t.x + t.w / 2.0;
	cairo_set_source_rgba(c, 1.0, 0.78, 0.30, 1);
	sun(c, cx, t.y - 50, 22);
	rounded(c, t.x, t.y, t.w, t.h, t.w / 2.0);
	cairo_set_source_rgba(c, 1, 1, 1, 0.14);
	cairo_fill(c);
	if (shown > 0) {
		double frac = tsx_level_to_pos(shown, minlvl, maxlvl);
		double fh = t.w + frac * (t.h - t.w);
		rounded(c, t.x, t.y + t.h - fh, t.w, fh, t.w / 2.0);
		cairo_set_source_rgba(c, 1.0, 0.78, 0.30, 0.95);
		cairo_fill(c);
		snprintf(s, sizeof s, "%d %%", overlay_percent(shown, maxlvl));
	} else snprintf(s, sizeof s, "-");
	cairo_set_source_rgba(c, 1, 1, 1, 0.95);
	text_center(c, s, cx, t.y + t.h + 32, 30, 1);
	/* How the level came about: auto (ALS) plus or minus the manual offset,
	 * or a fixed level from Home Assistant or a key action. */
	if (override > 0) snprintf(s, sizeof s, "fixed");
	else if (offset) snprintf(s, sizeof s, "%s %+d", als_auto == 1 ? "auto" : "sched", offset);
	else snprintf(s, sizeof s, "%s", als_auto == 1 ? "auto" : "sched");
	cairo_set_source_rgba(c, 1, 1, 1, 0.6);
	text_center(c, s, cx, t.y + t.h + 66, 18, 0);

	if (mode != FULL) return;
	static const char *label[NBTN] = { "", "Auto brightness", "Screen off", "Reload page", "Setup", "Close" };
	for (int i = B_AUTO; i < NBTN; i++) {
		struct rect b = r_btn[i];
		int on = i == B_AUTO && als_auto == 1, dis = i == B_AUTO && als_auto < 0;
		rounded(c, b.x, b.y, b.w, b.h, 22);
		if (pressed == i && press_inside) cairo_set_source_rgba(c, 1, 1, 1, 0.35);
		else if (on) cairo_set_source_rgba(c, 1.0, 0.78, 0.30, 0.85);
		else cairo_set_source_rgba(c, 1, 1, 1, dis ? 0.05 : 0.13);
		cairo_fill(c);
		if (on) cairo_set_source_rgba(c, 0.08, 0.09, 0.11, 1);
		else cairo_set_source_rgba(c, 1, 1, 1, dis ? 0.35 : 0.95);
		text_center(c, label[i], b.x + b.w / 2.0, b.y + b.h / 2.0 - (i == B_AUTO ? 14 : 0), 24, 1);
		if (i == B_AUTO)
			text_center(c, als_auto < 0 ? "no sensor" : on ? "on" : "off", b.x + b.w / 2.0, b.y + b.h / 2.0 + 24, 20, 0);
	}
}

/* ---- wl_shm buffers --------------------------------------------------------- */
static void buffer_release(void *data, struct wl_buffer *wb) { (void)wb; ((struct buffer *)data)->busy = 0; }
static const struct wl_buffer_listener buffer_listener = { .release = buffer_release };

static void buffer_free(struct buffer *b)
{
	if (b->cs) cairo_surface_destroy(b->cs);
	if (b->wb) wl_buffer_destroy(b->wb);
	if (b->data) munmap(b->data, b->size);
	memset(b, 0, sizeof *b);
}

static struct buffer *buffer_get(int w, int h)
{
	struct buffer *b = NULL;
	for (int i = 0; i < 2; i++) {
		if (bufs[i].busy) continue;
		if (bufs[i].wb && (bufs[i].w != w || bufs[i].h != h)) buffer_free(&bufs[i]);
		b = &bufs[i]; break;
	}
	if (!b) return NULL;
	if (b->wb) return b;
	int stride = w * 4, fd = memfd_create("tsx-overlay", MFD_CLOEXEC);
	b->size = (size_t)stride * h;
	if (fd < 0 || ftruncate(fd, b->size)) { logm("shm: %s", strerror(errno)); if (fd >= 0) close(fd); return NULL; }
	b->data = mmap(NULL, b->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (b->data == MAP_FAILED) { b->data = NULL; close(fd); return NULL; }
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, b->size);
	b->wb = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);
	wl_buffer_add_listener(b->wb, &buffer_listener, b);
	b->cs = cairo_image_surface_create_for_data(b->data, CAIRO_FORMAT_ARGB32, w, h, stride);
	b->w = w; b->h = h;
	return b;
}

static void redraw(void)
{
	if (!surface || !configured) return;
	struct buffer *b = buffer_get(surf_w, surf_h);
	if (!b) return;          /* both busy: the next event redraws */
	cairo_t *c = cairo_create(b->cs);
	draw(c, surf_w, surf_h);
	cairo_destroy(c);
	cairo_surface_flush(b->cs);
	b->busy = 1;
	wl_surface_attach(surface, b->wb, 0, 0);
	wl_surface_damage(surface, 0, 0, surf_w, surf_h);
	wl_surface_commit(surface);
}

/* ---- layer surface ------------------------------------------------------------ */
static void surface_destroy(void);

static void layer_configure(void *data, struct zwlr_layer_surface_v1 *l, uint32_t serial, uint32_t w, uint32_t h)
{
	(void)data;
	zwlr_layer_surface_v1_ack_configure(l, serial);
	if (w) surf_w = w;
	if (h) {
		/* The output height. It also changes when the screen turns. If
		 * another margin is due, set it and wait for the next configure. */
		out_h = (int)h + 2 * cur_mv;
		int mv = overlay_margin_v(mode == FULL, out_h);
		if (mv != cur_mv) {
			cur_mv = mv;
			zwlr_layer_surface_v1_set_margin(l, mv, MARGIN_R, mv, 0);
			wl_surface_commit(surface);
			return;
		}
		surf_h = h;
	}
	layout();       /* the height comes from the output */
	configured = 1;
	redraw();
}

static void layer_closed(void *data, struct zwlr_layer_surface_v1 *l)
{
	(void)data; (void)l;
	surface_destroy(); mode = HIDDEN;
}

static const struct zwlr_layer_surface_v1_listener layer_listener = {
	.configure = layer_configure, .closed = layer_closed,
};

static void surface_destroy(void)
{
	if (layer) zwlr_layer_surface_v1_destroy(layer);
	if (surface) wl_surface_destroy(surface);
	layer = NULL; surface = NULL; configured = 0;
	for (int i = 0; i < 2; i++) buffer_free(&bufs[i]);
	pressed = B_NONE; touch_id = -1; ptr_down = 0; drag_level = -1;
}

static void show(enum mode m)
{
	int w = m == FULL ? FULL_W : SLIDER_W, mv = overlay_margin_v(m == FULL, out_h);
	read_state();
	if (m == mode && surface) return;
	mode = m;
	surf_w = w;
	if (!surface) surf_h = 0; /* the configure event brings the height */
	layout();
	if (!surface) {
		surface = wl_compositor_create_surface(compositor);
		layer = zwlr_layer_shell_v1_get_layer_surface(layer_shell, surface, NULL,
			ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "tsx-overlay");
		zwlr_layer_surface_v1_add_listener(layer, &layer_listener, NULL);
		zwlr_layer_surface_v1_set_anchor(layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
			ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM);
		zwlr_layer_surface_v1_set_exclusive_zone(layer, -1);   /* never moves the page */
		zwlr_layer_surface_v1_set_keyboard_interactivity(layer, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
		configured = 0;
	}
	/* height 0 + top/bottom anchors: the compositor sizes it to the output */
	cur_mv = mv;
	zwlr_layer_surface_v1_set_margin(layer, mv, MARGIN_R, mv, 0);
	zwlr_layer_surface_v1_set_size(layer, w, 0);
	wl_surface_commit(surface);     /* -> configure -> redraw */
	if (verbose) logm("show %s", m == FULL ? "full" : "slider");
}

static void hide(void)
{
	if (mode == HIDDEN) return;
	surface_destroy();
	mode = HIDDEN;
	if (verbose) logm("hide");
}

static void keep_open(void) { hide_at = now_ms() + (mode == FULL ? full_ms : slider_ms); }

/* ---- input -------------------------------------------------------------------- */
static int hit(double x, double y)
{
	for (int i = 0; i < NBTN; i++) if (r_btn[i].w && in_rect(&r_btn[i], x, y)) return i;
	return B_NONE;
}

static void slider_at(double y)
{
	struct rect t = r_track;
	double frac = (t.y + t.h - y) / t.h;
	if (frac < 0) frac = 0;
	if (frac > 1) frac = 1;
	set_level(tsx_pos_to_level(frac, minlvl, maxlvl));
}

static void press_down(double x, double y)
{
	keep_open();
	pressed = hit(x, y); press_inside = 1;
	if (pressed == B_SLIDER) { drag_level = -1; read_state(); slider_at(y); }
	redraw();
}

static void press_move(double x, double y)
{
	if (pressed == B_NONE) return;
	keep_open();
	if (pressed == B_SLIDER) { slider_at(y); redraw(); return; }
	int in = in_rect(&r_btn[pressed], x, y);
	if (in != press_inside) { press_inside = in; redraw(); }
}

static void press_up(void)
{
	int b = pressed;
	pressed = B_NONE;
	if (b == B_SLIDER) { keep_open(); drag_hold = now_ms() + 700; redraw(); return; }
	if (b == B_NONE || !press_inside) { redraw(); return; }
	switch (b) {
	case B_AUTO:
		if (als_auto >= 0) { panelctl_send("als auto %s", als_auto == 1 ? "off" : "on"); als_auto = !als_auto; }
		keep_open(); redraw(); break;
	case B_BLANK: panelctl_send("blank on"); hide(); break;
	case B_RELOAD: panelctl_send("reload-page"); hide(); break;
	case B_SETUP: panelctl_send("setup"); hide(); break;
	case B_CLOSE: hide(); break;
	}
}

static void touch_down(void *d, struct wl_touch *t, uint32_t serial, uint32_t time, struct wl_surface *s,
		       int32_t id, wl_fixed_t x, wl_fixed_t y)
{
	(void)d; (void)t; (void)serial; (void)time;
	if (s != surface || touch_id >= 0) return;
	touch_id = id;
	press_down(wl_fixed_to_double(x), wl_fixed_to_double(y));
}
static void touch_up(void *d, struct wl_touch *t, uint32_t serial, uint32_t time, int32_t id)
{
	(void)d; (void)t; (void)serial; (void)time;
	if (id != touch_id) return;
	touch_id = -1; press_up();
}
static void touch_motion(void *d, struct wl_touch *t, uint32_t time, int32_t id, wl_fixed_t x, wl_fixed_t y)
{
	(void)d; (void)t; (void)time;
	if (id == touch_id) press_move(wl_fixed_to_double(x), wl_fixed_to_double(y));
}
static void touch_frame(void *d, struct wl_touch *t) { (void)d; (void)t; }
static void touch_cancel(void *d, struct wl_touch *t) { (void)d; (void)t; touch_id = -1; pressed = B_NONE; redraw(); }
static void touch_shape(void *d, struct wl_touch *t, int32_t id, wl_fixed_t a, wl_fixed_t b) { (void)d; (void)t; (void)id; (void)a; (void)b; }
static void touch_orient(void *d, struct wl_touch *t, int32_t id, wl_fixed_t o) { (void)d; (void)t; (void)id; (void)o; }
static const struct wl_touch_listener touch_listener = {
	.down = touch_down, .up = touch_up, .motion = touch_motion, .frame = touch_frame,
	.cancel = touch_cancel, .shape = touch_shape, .orientation = touch_orient,
};

static int ptr_on;
static void ptr_enter(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s, wl_fixed_t x, wl_fixed_t y)
{
	(void)d; (void)p; (void)serial;
	ptr_on = s == surface; ptr_x = wl_fixed_to_double(x); ptr_y = wl_fixed_to_double(y);
}
static void ptr_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s)
{
	(void)d; (void)p; (void)serial; (void)s;
	ptr_on = 0;
	if (ptr_down) { ptr_down = 0; press_inside = 0; press_up(); }
}
static void ptr_motion(void *d, struct wl_pointer *p, uint32_t time, wl_fixed_t x, wl_fixed_t y)
{
	(void)d; (void)p; (void)time;
	ptr_x = wl_fixed_to_double(x); ptr_y = wl_fixed_to_double(y);
	if (ptr_down) press_move(ptr_x, ptr_y);
}
static void ptr_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t time, uint32_t button, uint32_t st)
{
	(void)d; (void)p; (void)serial; (void)time; (void)button;
	if (!ptr_on) return;
	if (st == WL_POINTER_BUTTON_STATE_PRESSED && !ptr_down) { ptr_down = 1; press_down(ptr_x, ptr_y); }
	else if (st == WL_POINTER_BUTTON_STATE_RELEASED && ptr_down) { ptr_down = 0; press_up(); }
}
static void ptr_axis(void *d, struct wl_pointer *p, uint32_t time, uint32_t axis, wl_fixed_t v) { (void)d; (void)p; (void)time; (void)axis; (void)v; }
static void ptr_frame(void *d, struct wl_pointer *p) { (void)d; (void)p; }
static void ptr_axis_source(void *d, struct wl_pointer *p, uint32_t s) { (void)d; (void)p; (void)s; }
static void ptr_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a) { (void)d; (void)p; (void)t; (void)a; }
static void ptr_axis_discrete(void *d, struct wl_pointer *p, uint32_t a, int32_t v) { (void)d; (void)p; (void)a; (void)v; }
static void ptr_axis_v120(void *d, struct wl_pointer *p, uint32_t a, int32_t v) { (void)d; (void)p; (void)a; (void)v; }
static void ptr_axis_dir(void *d, struct wl_pointer *p, uint32_t a, uint32_t v) { (void)d; (void)p; (void)a; (void)v; }
static const struct wl_pointer_listener pointer_listener = {
	.enter = ptr_enter, .leave = ptr_leave, .motion = ptr_motion, .button = ptr_button,
	.axis = ptr_axis, .frame = ptr_frame, .axis_source = ptr_axis_source, .axis_stop = ptr_axis_stop,
	.axis_discrete = ptr_axis_discrete, .axis_value120 = ptr_axis_v120,
	.axis_relative_direction = ptr_axis_dir,
};

static void seat_caps(void *d, struct wl_seat *s, uint32_t caps)
{
	(void)d;
	if ((caps & WL_SEAT_CAPABILITY_TOUCH) && !touch) {
		touch = wl_seat_get_touch(s); wl_touch_add_listener(touch, &touch_listener, NULL);
	} else if (!(caps & WL_SEAT_CAPABILITY_TOUCH) && touch) { wl_touch_destroy(touch); touch = NULL; }
	if ((caps & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
		pointer = wl_seat_get_pointer(s); wl_pointer_add_listener(pointer, &pointer_listener, NULL);
	} else if (!(caps & WL_SEAT_CAPABILITY_POINTER) && pointer) { wl_pointer_destroy(pointer); pointer = NULL; }
}
static void seat_name(void *d, struct wl_seat *s, const char *n) { (void)d; (void)s; (void)n; }
static const struct wl_seat_listener seat_listener = { .capabilities = seat_caps, .name = seat_name };

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver)
{
	(void)d;
#define MIN(a, b) ((a) < (b) ? (a) : (b))
	if (!strcmp(iface, wl_compositor_interface.name))
		compositor = wl_registry_bind(r, name, &wl_compositor_interface, MIN(ver, 4));
	else if (!strcmp(iface, wl_shm_interface.name))
		shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
	else if (!strcmp(iface, wl_seat_interface.name) && !seat) {
		seat = wl_registry_bind(r, name, &wl_seat_interface, MIN(ver, 7));
		wl_seat_add_listener(seat, &seat_listener, NULL);
	} else if (!strcmp(iface, zwlr_layer_shell_v1_interface.name))
		layer_shell = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, MIN(ver, 4));
#undef MIN
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t name) { (void)d; (void)r; (void)name; }
static const struct wl_registry_listener reg_listener = { .global = reg_global, .global_remove = reg_remove };

/* ---- control FIFO ------------------------------------------------------------- */
static void ctl_open(void)
{
	struct stat st;
	if (ctl_fd >= 0) return;
	/* Open it read-write, so it never gives EOF when tsx-buttons closes its end. Group kiosk. */
	if ((ctl_fd = open(ctlpath, O_RDWR | O_NONBLOCK | O_CLOEXEC)) < 0) return;
	if (fstat(ctl_fd, &st) || !S_ISFIFO(st.st_mode)) { close(ctl_fd); ctl_fd = -1; return; }
	logm("listening on %s", ctlpath);
}

static void ctl_read(void)
{
	static char buf[256]; static size_t len;
	ssize_t r;
	while ((r = read(ctl_fd, buf + len, sizeof buf - 1 - len)) > 0) {
		len += r; buf[len] = 0;
		char *nl;
		while ((nl = strchr(buf, '\n'))) {
			*nl = 0;
			if (!strcmp(buf, "slider")) { want_mode = mode == FULL ? FULL : SLIDER; }
			else if (!strcmp(buf, "full")) want_mode = FULL;
			else if (!strcmp(buf, "hide")) want_mode = HIDDEN;
			else if (!strcmp(buf, "toggle")) want_mode = mode == HIDDEN ? FULL : HIDDEN;
			else logm("unknown command '%.40s'", buf);
			if (want_mode == HIDDEN) hide();
			else {
				show(want_mode); keep_open();
				if (read_state()) redraw();
			}
			memmove(buf, nl + 1, len - (nl + 1 - buf) + 1); len -= nl + 1 - buf;
		}
		if (len >= sizeof buf - 1) len = 0;
	}
}

static void on_sig(int s) { (void)s; sig_term = 1; }

int main(void)
{
	struct sigaction sa = { .sa_handler = on_sig };
	if (getenv("TSX_RUN_DIR")) rundir = getenv("TSX_RUN_DIR");
	if (getenv("OVERLAY_SLIDER_MS")) slider_ms = atoi(getenv("OVERLAY_SLIDER_MS"));
	if (getenv("OVERLAY_FULL_MS")) full_ms = atoi(getenv("OVERLAY_FULL_MS"));
	verbose = getenv("TSX_OVERLAY_VERBOSE") && atoi(getenv("TSX_OVERLAY_VERBOSE"));
	snprintf(ctlpath, sizeof ctlpath, "%s/overlay.ctl", rundir);
	snprintf(panelctl, sizeof panelctl, "%s/panelctl", rundir);
	snprintf(bstate, sizeof bstate, "%s/brightness.state", rundir);
	snprintf(astate, sizeof astate, "%s/als.state", rundir);
	sigemptyset(&sa.sa_mask);
	sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	if (!(dpy = wl_display_connect(NULL))) { logm("no Wayland display (WAYLAND_DISPLAY)"); return 1; }
	struct wl_registry *reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &reg_listener, NULL);
	wl_display_roundtrip(dpy);
	wl_display_roundtrip(dpy);
	if (!compositor || !shm || !layer_shell) {
		logm("compositor lacks %s", !layer_shell ? "wlr-layer-shell (cage?)" : "wl_compositor/wl_shm");
		return 1;
	}
	/* Load the fonts now, not on the first slide step. */
	{
		cairo_surface_t *cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 8, 8);
		cairo_t *c = cairo_create(cs);
		text_center(c, "0", 4, 4, 20, 1); text_center(c, "0", 4, 4, 20, 0);
		cairo_destroy(c); cairo_surface_destroy(cs);
	}
	ctl_open();
	logm("ready (%s%s)", ctlpath, ctl_fd < 0 ? ": not there yet, retrying" : "");

	while (!sig_term) {
		long long t = now_ms();
		int to = -1;
		if (mode != HIDDEN) {
			if (t >= hide_at && pressed == B_NONE) { hide(); continue; }
			to = drag_level > 0 ? 100 : 250;   /* follow tsx-idled/ALS changes while shown */
			if (hide_at - t < to) to = hide_at - t < 0 ? 0 : (int)(hide_at - t);
		}
		if (ctl_fd < 0) { ctl_open(); if (ctl_fd < 0 && (to < 0 || to > 5000)) to = 5000; }

		while (wl_display_prepare_read(dpy) != 0) wl_display_dispatch_pending(dpy);
		if (wl_display_flush(dpy) < 0 && errno != EAGAIN) { wl_display_cancel_read(dpy); break; }
		struct pollfd pfd[2] = { { .fd = wl_display_get_fd(dpy), .events = POLLIN }, { .fd = ctl_fd, .events = POLLIN } };
		int n = poll(pfd, ctl_fd >= 0 ? 2 : 1, to);
		if (n < 0) {
			wl_display_cancel_read(dpy);
			if (errno == EINTR) continue;
			logm("poll: %s", strerror(errno)); break;
		}
		if (pfd[0].revents & (POLLERR | POLLHUP)) { wl_display_cancel_read(dpy); logm("compositor gone"); break; }
		if (pfd[0].revents & POLLIN) { if (wl_display_read_events(dpy) < 0) break; }
		else wl_display_cancel_read(dpy);
		if (wl_display_dispatch_pending(dpy) < 0) break;
		if (ctl_fd >= 0 && (pfd[1].revents & POLLIN)) ctl_read();
		if (mode != HIDDEN && pressed == B_NONE) {
			int ch = read_state();
			/* The slider keeps the released value until tsx-idled has it. */
			if (drag_level > 0 && (level == drag_level || now_ms() >= drag_hold)) { drag_level = -1; ch = 1; }
			if (ch) redraw();
		}
	}
	hide();
	wl_display_flush(dpy);
	wl_display_disconnect(dpy);
	return 0;
}
