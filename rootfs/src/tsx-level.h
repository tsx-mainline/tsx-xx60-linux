/*
 * tsx-level.h: the level scale of the backlight, for tsx-idled and
 * tsx-overlay. It has no libm call, so every build line of the panel
 * programs can use it, and a host test can compile it on its own.
 *
 * A backlight with a wide range (for example 0..4095) needs a finer control
 * at the dark end. The eye sees a level of 600 as about half as bright as
 * 2400, not as a quarter. So the slider position pos (0 to 1) maps to the
 * level with a square: level = min + (max - min) * pos * pos. A backlight
 * with a small range (the xx60: 24 steps) stays linear, because every step
 * is already large.
 */
#ifndef TSX_LEVEL_H
#define TSX_LEVEL_H

#define TSX_LEVEL_WIDE 64   /* ranges wider than this use the square scale */

static inline double tsx_sqrt(double v)
{
	double x;
	int i;
	if (v <= 0) return 0;
	x = v > 1 ? v : 1;
	for (i = 0; i < 40; i++) x = 0.5 * (x + v / x);
	return x;
}

static inline int tsx_level_wide(int min, int max) { return max - min > TSX_LEVEL_WIDE; }

/* The slider position (0 to 1) of a level. Levels outside min..max give 0 or 1. */
static inline double tsx_level_to_pos(int level, int min, int max)
{
	double f;
	if (max <= min) return 1;
	if (level <= min) return 0;
	if (level >= max) return 1;
	f = (double)(level - min) / (max - min);
	return tsx_level_wide(min, max) ? tsx_sqrt(f) : f;
}

/* The level (min..max) of a slider position. */
static inline int tsx_pos_to_level(double pos, int min, int max)
{
	double f;
	if (max <= min) return max;
	if (pos <= 0) return min;
	if (pos >= 1) return max;
	f = tsx_level_wide(min, max) ? pos * pos : pos;
	return min + (int)(f * (max - min) + 0.5);
}

#endif
