/*--------------------------------------------------------------------------------
* file name: main.c
* DESCRIPTION:
* Cartesian Genetic Programming (CGP) Engine for hardware-in-the-loop evolution.
* and
* Fault Injection (SEU/MBU and Stuck-At)
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

	// initializing TMR Target with Watchdog Pattern
	// combinations (Y2, Y1, Y0) from states 7 to 0 packed into a 24-bit payload.
	// 001_011_100_011_001_011_100_010 = 0x002E32E2
	alt_putstr("Configuring Hardware Reference Truth Table (TMR)...\n");
	set_target_function(0x002E32E2);

	// clearing potential garbage after power-on from fault registers
	heal_all();

	const int NUM_TESTS = 3;
	int current_test = 0;

	while (1) {

		alt_putstr("\n\n======================================================\n");
		printf("--- Initiating test %d ---\n", current_test + 1);
		alt_putstr("======================================================\n");

		heal_all();

		Individual parent = create_seed(&rng_state);
		parent.fitness = evaluate_individual(&parent);

		if (parent.fitness != EXPECTED_SEED_FITNESS) {
			printf("[ERROR] SEED fitness %d. Logic is damaged.\nFreezing system.\n", parent.fitness);
			while(1);
		}

		if (current_test == 0) {
			alt_putstr("Output of LUT 0 - Stuck-At-0\n");
			inject_fault(0, 0x0000, 0x10, 0x00);
		} else if (current_test == 1) {
			alt_putstr("I0 of LUT 1 - Stuck-At-1 \n");
			inject_fault(1, 0x0000, 0x01, 0x01);
		} else if (current_test == 2) {
			alt_putstr("LUT 0, 1, 2 - MBU.\n");
			inject_fault(0, 0xFFFF, 0x00, 0x00); // Full bitwise negation of truth table 0
			inject_fault(1, 0x5555, 0x00, 0x00); // Negation of even-indexed bits in truth table 1
			inject_fault(2, 0xAAAA, 0x00, 0x00); // Negation of odd-indexed bits in truth table 2
		}


		parent.fitness = evaluate_individual(&parent);

		if (parent.fitness == MAX_FITNESS) {
			alt_putstr("Fitness is still 24. (Fault was injected into dead logic?) Skipping evolution.\n");
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

				child.fitness = evaluate_individual(&child);

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
		printf("Time taken: %lu clock cycles\n%lu clock cycles per generation\n", cycles_elapsed, cycles_elapsed/generation);

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
