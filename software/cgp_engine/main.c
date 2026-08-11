/*--------------------------------------------------------------------------------
* file name: main.c
* DESCRIPTION:
* Cartesian Genetic Programming (CGP) Engine for hardware-in-the-loop evolution.
* --------------------------------------------------------------------------------
*/

#include "io.h"
#include "system.h"
#include <stdio.h>
#include "sys/alt_stdio.h"
#include "sys/alt_timestamp.h" //for timer
#include "cgp_engine.h"
#include <unistd.h> // for usleep()

//#define SEED_CHECK
#define EXPECTED_SEED_FITNESS 24


int main() {
	alt_putstr("=== CGP on Nios II ===\n");

	// Initializing Timer for profiling (requires hardware timer syntetized)
	if (alt_timestamp_start() < 0) {
		alt_putstr("[WARN] Timer not found. Clock profiling disabled.\n");
	}

	uint32_t rng_state = 0x12345678;

	Individual parent = create_seed(&rng_state);

	// seed evaluation
	parent.fitness = hw_evaluate_individual(&parent);
	printf("Seed fitness: %d / %d\n", parent.fitness, MAX_FITNESS);

#ifdef SEED_CHECK
	if (parent.fitness != EXPECTED_SEED_FITNESS) {
		alt_putstr("[ERROR] Unexpected SEED fitness.\nFreezing system.\n");
		while(1);
	}
#endif

	const int NUM_TESTS = 3;
	int current_test = 0;

	while (1) {

		alt_putstr("\n\n======================================================\n");
		printf("--- Initiating test %d ---\n", current_test + 1);
		alt_putstr("======================================================\n");

		if (current_test == 0) {
			alt_putstr("Zeroing Truth Table of LUT 0 (fault in y0 logic)\n");
			parent.F_table[0] = 0x0000;
		} else if (current_test == 1) {
			alt_putstr("Assigning output of LUT29 to y1 \n");
			parent.outputs = (parent.outputs & ~(0x3F << 6)) | (32 << 6);
			parent.F_table[29] = 0x0000;
		} else if (current_test == 2) {
			alt_putstr("Zeroing truth tables of 3 nodes connected directly to external outputs.\n");
			uint32_t y0_src = parent.outputs & 0x3F;
			uint32_t y1_src = (parent.outputs >> 6) & 0x3F;
			uint32_t y2_src = (parent.outputs >> 12) & 0x3F;

			if (y0_src >= NUM_INPUTS) parent.F_table[y0_src - NUM_INPUTS] = 0x0000;
			if (y1_src >= NUM_INPUTS) parent.F_table[y1_src - NUM_INPUTS] = 0x0000;
			if (y2_src >= NUM_INPUTS) parent.F_table[y2_src - NUM_INPUTS] = 0x0000;
		}

		parent.fitness = hw_evaluate_individual(&parent);

		if (parent.fitness == MAX_FITNESS) {
			alt_putstr("Fitness is still 24. Skipping evolution.\n");
			print_netlist(&parent);
			current_test++;
			continue;
		}

		printf("\nFitness dropped to %d. Starting (1+4)-ES evolution.\n", parent.fitness);

		int generation = 0;
		uint32_t time_start = (uint32_t)alt_timestamp();

		while (parent.fitness < MAX_FITNESS) {
			generation++;
			Individual best_child;
			int best_child_fitness = -1;

			int i;
			for (i = 0; i < LAMBDA; i++) {
				Individual child;
				mutate_individual(&parent, &child, &rng_state);

				child.fitness = hw_evaluate_individual(&child);

				if (child.fitness > best_child_fitness) {
					best_child = child;
					best_child_fitness = child.fitness;
				}

				if (child.fitness == MAX_FITNESS) break;
			}

			if (best_child_fitness >= parent.fitness) {
				parent = best_child;
			}
		}

		uint32_t time_end = (uint32_t)alt_timestamp();
		uint32_t cycles_elapsed = time_end - time_start;

		printf("\n[SUCCESS] Max fitness achieved in Generation %d!\n", generation);
		printf("Time taken: %lu clock cycles\n", cycles_elapsed);

		print_netlist(&parent);

		current_test++;

		if (current_test >= NUM_TESTS) break;

		alt_putstr("Waiting 3 seconds before next test.\n\n");
		usleep(3000000);
	}

	alt_putstr("=== TESTS COMPLETED. ===\n");
	while(1);
	return 0;
}
