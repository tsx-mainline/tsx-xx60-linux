/* i2crd BUS ADDR N CMDBYTE... : read-only I2C probe for unit A (Android, no i2c-tools).
 * Writes CMDBYTEs then reads N bytes after a repeated start (I2C_RDWR, so it also
 * works on addresses bound to a kernel driver), prints them in hex.
 * Only the command phase is written: for the TFA9890 that is the register pointer,
 * for the ZL38051 the HBI read command; no register is ever modified. */

#include <linux/i2c.h>
#include <linux/i2c-dev.h>




int main(int argc, char **argv)
{
	unsigned char w[16], r[256]; char dev[32]; int i, nw, n, fd;
	if (argc < 5) { fprintf(stderr, "usage: i2crd BUS ADDR N CMD...\n"); return 2; }
	snprintf(dev, sizeof(dev), "/dev/i2c-%s", argv[1]);
	n = strtol(argv[3], 0, 0); nw = argc - 4;
	if (n < 1 || n > 256 || nw > 16) return 2;
	for (i = 0; i < nw; i++) w[i] = strtol(argv[4 + i], 0, 0);
	/* refuse HBI write commands (bit 7 of the length byte) to the ZL38051 */
	if (strtol(argv[2], 0, 0) == 0x45 && (w[nw - 1] & 0x80)) { fprintf(stderr, "write refused\n"); return 2; }
	struct i2c_msg m[2] = {
		{ .addr = strtol(argv[2], 0, 0), .flags = 0, .len = nw, .buf = w },
		{ .addr = strtol(argv[2], 0, 0), .flags = I2C_M_RD, .len = n, .buf = r },
	};
	struct i2c_rdwr_ioctl_data d = { .msgs = m, .nmsgs = 2 };
	fd = open(dev, O_RDWR);
	if (fd < 0 || ioctl(fd, I2C_RDWR, &d) < 0) { perror("i2crd"); return 1; }
	{ static const char hx[] = "0123456789abcdef"; char o[4];
	  for (i = 0; i < n; i++) { o[0] = hx[r[i] >> 4]; o[1] = hx[r[i] & 15]; o[2] = ' ';
	    write(1, o, (i & 1) ? 3 : 2); }
	  write(1, "\n", 1); }
	return 0;
}
