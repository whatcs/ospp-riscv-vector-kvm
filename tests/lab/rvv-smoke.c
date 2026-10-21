/* SPDX-License-Identifier: GPL-2.0-only */
/* Exercise RVV arithmetic in L1/L2 without compiler auto-vectorization. */
#include <stdint.h>
#include <stdio.h>
#include <stddef.h>

int main(void)
{
	uint32_t a[257], b[257], out[257];
	unsigned long vlenb;
	size_t offset = 0;

	__asm__ volatile (".option push\n.option arch, +v\n"
			  "csrr %0, vlenb\n.option pop" : "=r" (vlenb));
	for (size_t i = 0; i < 257; i++) {
		a[i] = (uint32_t)(i * 17 + 3);
		b[i] = (uint32_t)(i * 29 + 11);
		out[i] = 0;
	}
	while (offset < 257) {
		size_t vl;

		__asm__ volatile (
			".option push\n.option arch, +v\n"
			"vsetvli %0, %4, e32, m1, ta, ma\n"
			"vle32.v v0, (%1)\n"
			"vle32.v v1, (%2)\n"
			"vadd.vv v2, v0, v1\n"
			"vse32.v v2, (%3)\n.option pop"
			: "=&r" (vl)
			: "r" (a + offset), "r" (b + offset),
			  "r" (out + offset), "r" (257 - offset)
			: "memory");
		offset += vl;
	}
	for (size_t i = 0; i < 257; i++) {
		if (out[i] != a[i] + b[i]) {
			printf("RVV_FAIL index=%zu got=%u expected=%u\n",
			       i, out[i], a[i] + b[i]);
			return 1;
		}
	}
	printf("RVV_PASS elements=257 vlenb=%lu VLEN=%lu\n", vlenb, vlenb * 8);
	return 0;
}
