/*
 * tsx-peak: level meter for the TSW-1060 audio bring-up .
 * Reads a WAV file or raw PCM (S16_LE or S32_LE) from a file or stdin and
 * prints, per channel, the peak and RMS level in dBFS, the DC offset and
 * the number of full-scale samples.
 *
 *   arecord -D hw:TSW1060,1 -f S16_LE -r 48000 -c 2 -d 5 -t raw | tsx-peak -c 2
 *   tsx-peak rec.wav                       (format from the WAV header)
 *   arecord ... | tsx-peak -c 2 -i 250     (one line every 250 ms of audio)
 *   tsx-peak -f s32 -c 2 raw.bin           (S32_LE, e.g. AUDIN raw=1 words)
 *
 * Options: -c CHANNELS (2), -r RATE (48000, for -i), -f s16|s32 (s16),
 *          -i MS (interval output), -q (only the summary line).
 * Exit status 3 when every sample of every channel is zero.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAXCH 8

struct acc {
	double sum, sum2, peak;
	unsigned long n, clip;
};

static double db(double v) { return v > 0 ? 20 * log10(v) : -150.0; }

static void report(const char *tag, struct acc *a, int ch, double fs)
{
	int c;

	printf("%s", tag);
	for (c = 0; c < ch; c++) {
		double mean = a[c].n ? a[c].sum / a[c].n : 0;
		double rms = a[c].n ? sqrt(a[c].sum2 / a[c].n) : 0;

		printf("  ch%d peak %6.1f dBFS rms %6.1f dBFS dc %+.4f clip %lu", c,
		       db(a[c].peak / fs), db(rms / fs), mean / fs, a[c].clip);
	}
	printf("\n");
	fflush(stdout);
}

static int wav_header(FILE *f, int *ch, int *rate, int *bits)
{
	unsigned char h[12], ck[8];
	uint32_t len;

	if (fread(h, 1, 12, f) != 12 || memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVE", 4))
		return -1;
	while (fread(ck, 1, 8, f) == 8) {
		len = ck[4] | ck[5] << 8 | ck[6] << 16 | (uint32_t)ck[7] << 24;
		if (!memcmp(ck, "fmt ", 4)) {
			unsigned char fm[40];

			if (len < 16 || len > sizeof(fm) || fread(fm, 1, len, f) != len)
				return -1;
			*ch = fm[2] | fm[3] << 8;
			*rate = fm[4] | fm[5] << 8 | fm[6] << 16 | fm[7] << 24;
			*bits = fm[14] | fm[15] << 8;
		} else if (!memcmp(ck, "data", 4)) {
			return 0;
		} else {
			while (len--)
				if (fgetc(f) == EOF)
					return -1;
		}
	}
	return -1;
}

int main(int argc, char **argv)
{
	int ch = 2, rate = 48000, bits = 16, ival = 0, quiet = 0, o, c, nonzero = 0;
	struct acc tot[MAXCH], part[MAXCH];
	unsigned long frames = 0, per = 0, inpart = 0;
	FILE *f = stdin;
	double fs;

	while ((o = getopt(argc, argv, "c:r:f:i:q")) != -1) {
		switch (o) {
		case 'c': ch = atoi(optarg); break;
		case 'r': rate = atoi(optarg); break;
		case 'f': bits = strcmp(optarg, "s32") ? 16 : 32; break;
		case 'i': ival = atoi(optarg); break;
		case 'q': quiet = 1; break;
		default:
			fprintf(stderr, "usage: tsx-peak [-c ch] [-r rate] [-f s16|s32] [-i ms] [-q] [file]\n");
			return 1;
		}
	}
	if (optind < argc && strcmp(argv[optind], "-")) {
		f = fopen(argv[optind], "rb");
		if (!f) {
			perror(argv[optind]);
			return 1;
		}
		if (wav_header(f, &ch, &rate, &bits))
			rewind(f);	/* raw data */
	}
	if (ch < 1 || ch > MAXCH || (bits != 16 && bits != 32)) {
		fprintf(stderr, "tsx-peak: unsupported format (%d ch, %d bit)\n", ch, bits);
		return 1;
	}
	fs = bits == 16 ? 32768.0 : 2147483648.0;
	per = ival > 0 ? (unsigned long)rate * ival / 1000 : 0;
	memset(tot, 0, sizeof(tot));
	memset(part, 0, sizeof(part));

	for (;;) {
		unsigned char buf[MAXCH * 4];
		size_t sz = (size_t)ch * bits / 8;

		if (fread(buf, 1, sz, f) != sz)
			break;
		for (c = 0; c < ch; c++) {
			double v;

			if (bits == 16)
				v = (int16_t)(buf[2 * c] | buf[2 * c + 1] << 8);
			else
				v = (int32_t)((uint32_t)buf[4 * c] | (uint32_t)buf[4 * c + 1] << 8 |
					      (uint32_t)buf[4 * c + 2] << 16 | (uint32_t)buf[4 * c + 3] << 24);
			if (v != 0)
				nonzero = 1;
			for (o = 0; o < 2; o++) {
				struct acc *a = o ? &part[c] : &tot[c];

				a->sum += v;
				a->sum2 += v * v;
				if (fabs(v) > a->peak)
					a->peak = fabs(v);
				if (fabs(v) >= fs - 1)
					a->clip++;
				a->n++;
			}
		}
		frames++;
		if (per && ++inpart >= per) {
			char tag[32];

			if (!quiet) {
				snprintf(tag, sizeof(tag), "%8.3f s", (double)frames / rate);
				report(tag, part, ch, fs);
			}
			memset(part, 0, sizeof(part));
			inpart = 0;
		}
	}
	printf("frames %lu (%.2f s at %d Hz, %d ch, %d bit)\n", frames,
	       (double)frames / rate, rate, ch, bits);
	report("total", tot, ch, fs);
	return nonzero ? 0 : 3;
}
