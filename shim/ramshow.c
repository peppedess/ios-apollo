/*
 * RAM log viewer (built with -DSHIM_RAMSHOW): show the tail of the previous XNU run's console on the screen,
 * straight from DRAM, which survives the warm reset into fastboot. Read-only: nothing is written to UFS, so it
 * works while userdata still holds Android (apollo k1). Sources, as ramlog.c: XNU's uncached ring mirror at
 * 0x1fa000000 ("SWEETMIR"), else the shim's mailbox at 0x1fbe00000 pointing at the cached ring.
 * Pages of RAMSHOW_PAGE_S seconds, newest page last, then reset into fastboot.
 */
#include <stdint.h>
#include "console.h"
#include "log.h"
#include "ramshow.h"
#include "util.h"

#define MIRROR_PA	0x1fa000000UL
#define MAILBOX_PA	0x1fbe00000UL
#define RING_SIZE	(4u << 20)
#ifndef RAMSHOW_TAIL
#define RAMSHOW_TAIL	(24 * 1024)
#endif
#ifndef RAMSHOW_PAGE_S
#define RAMSHOW_PAGE_S	15
#endif

static char tail[RAMSHOW_TAIL];

static int magic_is(const volatile char *m, const char *want)
{
	for (int i = 0; i < 8; i++)
		if (m[i] != want[i])
			return 0;
	return 1;
}

static void title(const char *s, unsigned page)
{
	char t[64];
	unsigned n = 0;
	while (s[n] && n < 40) {
		t[n] = s[n];
		n++;
	}
	t[n++] = ' ';
	if (page >= 10)
		t[n++] = (char)('0' + page / 10 % 10);
	t[n++] = (char)('0' + page % 10);
	t[n++] = '\n';
	con_text(t, n, YELLOW);
}

void ramshow_run(void)
{
	uint64_t ring = 0, total = 0;
	const char *src = "no log in RAM";
	volatile char *mh = (volatile char *)MIRROR_PA;
	if (magic_is(mh, "SWEETMIR") && *(volatile uint32_t *)(MIRROR_PA + 16) == RING_SIZE) {
		ring = MIRROR_PA + 0x1000;
		total = *(volatile uint64_t *)(MIRROR_PA + 8);
		src = "xnu log (uncached mirror) page";
	} else {
		volatile uint64_t *mb = (volatile uint64_t *)MAILBOX_PA;
		uint64_t r = mb[1], t = mb[2];
		if (magic_is((volatile char *)MAILBOX_PA, "SWEETRAM") && r >= 0x100000000UL && r < 0x200000000UL &&
		    t >= 0x100000000UL && t < 0x200000000UL && !(r & 7) && !(t & 7)) {
			ring = r;
			total = *(volatile uint64_t *)t;
			src = "xnu log (cached ring) page";
		}
	}
	unsigned n = 0;
	if (ring && total) {
		n = total < RAMSHOW_TAIL ? (unsigned)total : RAMSHOW_TAIL;
		uint64_t start = total - n;
		for (unsigned i = 0; i < n; i++) {
			char c = *(volatile char *)(ring + (start + i) % RING_SIZE);
			tail[i] = (c == '\n' || (c >= 32 && c < 127)) ? c : '.';
		}
	}
	log_printf("ramshow: %s, total %lu, showing %u\n", src, total, n);
	if (!n) {
		con_clear(0xff401010);
		con_home();
		con_text(log_buf, log_len, WHITE);
		delay_ms(30000);
		return;
	}
	/* Paginate: first find the page starts, then show them in order (last page = newest lines). */
	unsigned off = 0, page = 0;
	while (off < n) {
		con_clear(0xff102030);
		con_home();
		title(src, ++page);
		unsigned used = con_text(tail + off, n - off, WHITE);
		if (!used)
			break;
		off += used;
		uint64_t t0 = ticks_now();
		while (ticks_now() - t0 < (uint64_t)RAMSHOW_PAGE_S * 19200000)
			;
	}
	/* Hold the newest page longer. */
	delay_ms(30000);
}
