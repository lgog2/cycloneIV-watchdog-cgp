/*--------------------------------------------------------------------------------
* file name: main.c
* DESCRIPTION:
* Test of hardware xorshift32 PRNG generator - checking inf values generated are identical with software version
* --------------------------------------------------------------------------------
*/

#include <stdio.h>
#include <stdint.h>
#include "system.h"
#include "io.h"

// 32-bit PRNG (George Marsaglia, 2003) - software
uint32_t xorshift32_sw(uint32_t *state) {
	uint32_t x = *state;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	*state = x;
	return x;
}

void test_hardware_prng() {
	printf("\nTest of hardware xorshift PRNG\n");

	uint32_t seed = 0xDEADBEEF;

	// injection of seed to hardware xorshift32 module
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, 100 * 4, seed);

	int errors = 0;
	for(int i = 0; i < 10; i++) {
		// next software PRNG value
		uint32_t expected = xorshift32_sw(&seed);

		// sneding prng_step_cmd to wrapper
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, 61 * 4, 0x02);

		// next hardware PRNG value
		uint32_t hardware_val = IORD_32DIRECT(CGP_WATCHDOG_BASE, 101 * 4);

		if(hardware_val != expected) {
			printf("ITER %d | FAIL -> SW: 0x%08lX | HW: 0x%08lX\n", i, expected, hardware_val);
			errors++;
		} else {
			printf("ITER %d | PASS -> 0x%08lX\n", i, expected);
		}
	}

	if(errors == 0) {
		printf("[TEST SUCCESS - hardware xorshift32 module generated the same values as software version.\n");
	} else {
		printf("TEST FAILURE - hardware xorshift32 module generated different values then software version in %d cases.\n", errors);
	}
}


int main() {
	test_hardware_prng();
	return 0;
}
