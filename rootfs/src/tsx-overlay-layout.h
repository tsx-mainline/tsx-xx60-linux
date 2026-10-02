/*
 * tsx-overlay-layout.h: the size and layout math of tsx-overlay. It has no
 * Wayland or cairo code, so a host test can compile it on its own
 * (rootfs/tests/test-orientation.sh).
 *
 * The overlay is a layer surface at the right edge of the output, anchored
 * top, right and bottom. The compositor gives it the output height minus a
 * top and a bottom margin. On the landscape panels the surface is 720 px
 * (full) or 600 px (slider) high on 1280x800, and 520 px or 400 px on
 * 1024x600. A portrait output (panel.conf ORIENTATION portrait or
 * portrait-flipped: 800x1280 or 600x1024) is much higher. The margins then
 * grow, so the surface is never higher than on the 10-inch landscape panel.
 * The surface stays centered on the edge.
 */
#ifndef TSX_OVERLAY_LAYOUT_H
#define TSX_OVERLAY_LAYOUT_H

enum { B_NONE = -1, B_SLIDER, B_AUTO, B_BLANK, B_RELOAD, B_SETUP, B_CLOSE, NBTN };

struct rect { int x, y, w, h; };

#define SLIDER_W 150
#define SLIDER_MARGIN_V 100
#define SLIDER_MAX_H 600
#define FULL_W 440
#define FULL_MARGIN_V 40
#define FULL_MAX_H 720
#define FULL_BTN_H 150
#define MARGIN_R 16

/* The top margin (the same as the bottom margin) on an output out_h px high.
 * out_h is 0 while the height is not known yet. */
static inline int overlay_margin_v(int full, int out_h)
{
	int mv = full ? FULL_MARGIN_V : SLIDER_MARGIN_V, max_h = full ? FULL_MAX_H : SLIDER_MAX_H;
	if (out_h - 2 * mv > max_h) mv = (out_h - max_h) / 2;
	return mv;
}

/* The slider track and the buttons, in surface coordinates, for a surface
 * h px high. The width is SLIDER_W or FULL_W. */
static inline void overlay_layout(int full, int h, struct rect *track, struct rect btn[NBTN])
{
	for (int i = 0; i < NBTN; i++) btn[i] = (struct rect){ 0, 0, 0, 0 };
	if (h <= 0) h = 600;
	if (!full) {
		*track = (struct rect){ 40, 90, 70, h - 200 };
		btn[B_SLIDER] = (struct rect){ 0, 60, SLIDER_W, h - 100 };
	} else {
		int bx = 190, bw = FULL_W - bx - 24, gap = 20, by = 24;
		int bh = (h - 2 * by - (NBTN - B_AUTO - 1) * gap) / (NBTN - B_AUTO);
		if (bh > FULL_BTN_H) bh = FULL_BTN_H;
		*track = (struct rect){ 45, 110, 80, h - 200 };
		btn[B_SLIDER] = (struct rect){ 0, 70, 170, h - 120 };
		for (int i = B_AUTO; i < NBTN; i++) btn[i] = (struct rect){ bx, by + (i - B_AUTO) * (bh + gap), bw, bh };
	}
}

/* The slider offset for the level l on the base b of tsx-idled. The offset
 * has the range of the backlight (maxlvl), so a 0..4095 backlight can use the
 * whole slider. A fixed limit of 31 steps moved a 0..4095 backlight by 31 at
 * most. A 0..23 backlight keeps its old range, because |l - b| < 23 there. */
static inline int overlay_offset(int l, int b, int maxlvl)
{
	int off = l - b;
	if (maxlvl < 1) maxlvl = 1;
	if (off > maxlvl) off = maxlvl;
	if (off < -maxlvl) off = -maxlvl;
	return off;
}

/* The brightness as a percent of the backlight maximum, rounded. The overlay
 * shows it under the slider. A level of 0 or less shows 0. */
static inline int overlay_percent(int level, int maxlvl)
{
	if (level <= 0 || maxlvl <= 0) return 0;
	if (level >= maxlvl) return 100;
	return (int)(((long long)level * 100 + maxlvl / 2) / maxlvl);
}

#endif
