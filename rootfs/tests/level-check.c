/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Checks of src/tsx-level.h and the percent label of tsx-overlay-layout.h.
 * The test compiles this file without -lm. */
#include <stdio.h>
#include "../src/tsx-overlay-layout.h"
#include "../src/tsx-level.h"

static int fails;
#define CHECK(c, ...) do { if (c) printf("  ok: " __VA_ARGS__), puts(""); else { printf("  FAIL: " __VA_ARGS__), puts(""); fails++; } } while (0)

int main(void)
{
	int l, prev, mono = 1, round = 1, steps_low = 0;
	double p;

	/* wide range: the floor is 123, the top 4095 */
	CHECK(tsx_pos_to_level(0, 123, 4095) == 123, "wide: position 0 is the floor");
	CHECK(tsx_pos_to_level(1, 123, 4095) == 4095, "wide: position 1 is the top");
	CHECK(tsx_pos_to_level(-1, 123, 4095) == 123 && tsx_pos_to_level(2, 123, 4095) == 4095, "wide: positions outside 0..1 are cut");
	CHECK(tsx_pos_to_level(0.5, 123, 4095) < 123 + (4095 - 123) / 2 - 500, "wide: the middle of the slider is below the middle level (%d)", tsx_pos_to_level(0.5, 123, 4095));
	prev = 0;
	for (p = 0; p <= 1.0001; p += 0.001) {
		l = tsx_pos_to_level(p, 123, 4095);
		if (l < prev) mono = 0;
		prev = l;
	}
	CHECK(mono, "wide: the level never goes down when the position goes up");
	for (l = 123; l <= 4095; l += 7) {
		int back = tsx_pos_to_level(tsx_level_to_pos(l, 123, 4095), 123, 4095);
		if (back < l - 1 || back > l + 1) round = 0;
	}
	CHECK(round, "wide: level -> position -> level returns the level (within 1)");
	for (p = 0; p < 0.1; p += 0.001) if (tsx_pos_to_level(p, 123, 4095) < 123 + 40) steps_low++;
	CHECK(steps_low > 50, "wide: the bottom tenth of the slider covers only the dark levels (%d samples)", steps_low);
	CHECK(tsx_level_to_pos(123, 123, 4095) == 0 && tsx_level_to_pos(4095, 123, 4095) == 1, "wide: ends of level_to_pos");
	CHECK(tsx_level_to_pos(50, 123, 4095) == 0, "wide: a level below the floor shows as position 0");

	/* narrow range: 24 steps stay linear */
	CHECK(tsx_pos_to_level(0, 1, 23) == 1 && tsx_pos_to_level(1, 1, 23) == 23, "narrow: ends");
	CHECK(tsx_pos_to_level(0.5, 1, 23) == 12, "narrow: the middle is linear (%d)", tsx_pos_to_level(0.5, 1, 23));
	mono = 1; prev = 0;
	for (p = 0; p <= 1.0001; p += 0.001) { l = tsx_pos_to_level(p, 1, 23); if (l < prev) mono = 0; prev = l; }
	CHECK(mono, "narrow: monotone");
	round = 1;
	for (l = 1; l <= 23; l++) if (tsx_pos_to_level(tsx_level_to_pos(l, 1, 23), 1, 23) != l) round = 0;
	CHECK(round, "narrow: every step maps back to itself");
	CHECK(tsx_pos_to_level(0.5, 5, 5) == 5, "a range of one level");
	CHECK(tsx_sqrt(4) > 1.9999 && tsx_sqrt(4) < 2.0001 && tsx_sqrt(0.25) > 0.4999 && tsx_sqrt(0.25) < 0.5001, "tsx_sqrt without libm");

	/* the label stays the level as a percent of the top level */
	CHECK(overlay_percent(123, 4095) == 3 && overlay_percent(4095, 4095) == 100 && overlay_percent(2048, 4095) == 50, "the percent label");

	printf("== %d failure(s)\n", fails);
	return fails != 0;
}
