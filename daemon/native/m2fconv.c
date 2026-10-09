/*
 * m2fconv -- frame store planes to I420, for mpeg2fpgad (loaded with ctypes).
 *
 * The same transformation as mpeg2fpgad/i420.py, without the GIL: ctypes
 * releases it for the length of the call, so the daemon's other threads
 * (upload, socket writes) keep running while a frame is converted. In pure
 * Python this cost ~24 ms per 704x480 frame with the GIL held, which together
 * with the socket writes capped delivery at ~12 fps (measured on the board,
 * 2026-10-08); a process pool did not help, the pickling ate the gain.
 *
 * Reads straight from the frame store mapping, so the capture thread does
 * one pass over uncached DRAM instead of a copy and then a conversion.
 *
 * Freestanding on purpose: no libc, so it cross-compiles with the bare
 * riscv64-linux-gnu-gcc used for the kernel module and loads on the board
 * with nothing else installed.
 *
 *   riscv64-linux-gnu-gcc -O2 -shared -fPIC -nostdlib -ffreestanding \
 *       -o libm2fconv.so m2fconv.c
 *
 * Frame store layout (webserver/framestore.py, tools/framecmp): pixels are
 * signed (offset -128) and the leftmost pixel of each 64-bit word is its most
 * significant byte, so in DRAM byte order the 8 pixels of a word run right to
 * left. Rows are `stride` bytes (16 * mb_width luma, 8 * mb_width chroma);
 * the output is cropped to width x height, rows packed.
 */

#include <stdint.h>

#define SIGN 0x8080808080808080ULL

/* byte reversal with masks and shifts: __builtin_bswap64 would need libgcc's
 * __bswapdi2 on a core without Zbb, which this freestanding .so cannot link */
static inline uint64_t swap64(uint64_t x)
{
	x = ((x & 0x00FF00FF00FF00FFULL) << 8) | ((x >> 8) & 0x00FF00FF00FF00FFULL);
	x = ((x & 0x0000FFFF0000FFFFULL) << 16) | ((x >> 16) & 0x0000FFFF0000FFFFULL);
	return (x << 32) | (x >> 32);
}

static void plane(const uint8_t *src, unsigned stride, unsigned width,
		  unsigned height, uint8_t *dst)
{
	unsigned r, x;

	for (r = 0; r < height; r++) {
		const uint64_t *row = (const uint64_t *)(src + (unsigned long)r * stride);
		uint8_t *out = dst + (unsigned long)r * width;

		/* The frame store is uncached: each load costs a full DRAM round
		 * trip. Issue eight before using any, so the in-order U54 keeps
		 * them in flight together instead of waiting on each in turn. */
		for (x = 0; x + 64 <= width; x += 64) {
			const uint64_t *p = row + x / 8;
			uint64_t w[8];
			int i, k;

			w[0] = p[0]; w[1] = p[1]; w[2] = p[2]; w[3] = p[3];
			w[4] = p[4]; w[5] = p[5]; w[6] = p[6]; w[7] = p[7];
			/* compiler barrier: without it GCC interleaves each load with
			 * the first store that uses it (ld; sd; ld; sd ...), which
			 * stalls the core on every load -- 31 ms per frame against
			 * 4.6 ms for memcpy, which groups its loads like this */
			__asm__ volatile("" : "+r"(w[0]), "+r"(w[1]), "+r"(w[2]), "+r"(w[3]),
					      "+r"(w[4]), "+r"(w[5]), "+r"(w[6]), "+r"(w[7]));
			if (!((unsigned long)(out + x) & 7)) {
				/* whole words out: one 64-bit store per 8 pixels instead
				 * of eight byte stores (~17 cycles a byte before) */
				uint64_t *o = (uint64_t *)(out + x);

				for (i = 0; i < 8; i++)
					o[i] = swap64(w[i] ^ SIGN);
			} else {
				/* unaligned 64-bit stores trap to firmware on RISC-V */
				for (i = 0; i < 8; i++) {
					uint64_t v = w[i] ^ SIGN;

					for (k = 0; k < 8; k++)
						out[x + 8 * i + k] = (uint8_t)(v >> (8 * (7 - k)));
				}
			}
		}
		for (; x + 8 <= width; x += 8) {
			/* one 64-bit load from uncached memory; the leftmost pixel is
			 * the most significant byte. Shifts, not __builtin_bswap64:
			 * without Zbb that becomes a call to libgcc's __bswapdi2,
			 * which a freestanding .so cannot resolve on the board. */
			uint64_t w = row[x / 8] ^ SIGN;
			int k;

			for (k = 0; k < 8; k++)
				out[x + k] = (uint8_t)(w >> (8 * (7 - k)));
		}
		if (x < width) {
			uint64_t w = row[x / 8] ^ SIGN;
			unsigned k;

			for (k = 0; x + k < width; k++)
				out[x + k] = (uint8_t)(w >> (8 * (7 - k)));
		}
	}
}

/*
 * y/cb/cr: the three native planes of one frame buffer; out: width*height*3/2
 * bytes. Returns the number of bytes written.
 */
unsigned long m2f_to_i420(const uint8_t *y, const uint8_t *cb, const uint8_t *cr,
			  unsigned width, unsigned height, uint8_t *out)
{
	unsigned mbw = (width + 15) / 16;
	unsigned long ysz = (unsigned long)width * height;
	unsigned long csz = (unsigned long)(width / 2) * (height / 2);

	plane(y, 16 * mbw, width, height, out);
	plane(cb, 8 * mbw, width / 2, height / 2, out + ysz);
	plane(cr, 8 * mbw, width / 2, height / 2, out + ysz + csz);
	return ysz + 2 * csz;
}
