/*--------------------------------------------------------------------------------
* file name: cgp_engine.c
* DESCRIPTION:
* Cartesian Genetic Programming (CGP) Engine for hardware-in-the-loop evolution.
* --------------------------------------------------------------------------------
*/

#include <stdio.h>
#include "cgp_engine.h"
#include "system.h"
#include "io.h"

// Static probability thresholds
// Xorshift space: 0 to 4294967295 (2^32 - 1)
#define MUTATION_TH_F  141733920UL	// ~3.3% of 2^32
#define MUTATION_TH_IN 34359738UL	// ~0.8% of 2^32


// 32-bit PRNG (George Marsaglia, 2003)
static inline uint32_t xorshift32(uint32_t *state) {
	uint32_t x = *state;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	*state = x;
	return x;
}


// polling for fault instead of of interrupts
void hw_wait_for_fault() {
	volatile uint32_t status;
	do {
		status = IORD_32DIRECT(CGP_WATCHDOG_BASE, 62 * 4);
	} while ((status & 0x03) == 0);
}


Individual create_seed(uint32_t *rng_state) {
	Individual ind;
	int i, j;

	// LUT 0: y0 = (x2 & !x0) | x1
	ind.F_table[0] = 0xDCDC;

	// inputs hardcoded: I0(bits 4-0)=x0(0), I1(bits 9-5) =x1(1), I2(bits 14-10)=x2(2).
	// I3 (bits 19-15) any from allowed (0, 1, 2)

	// Lemire's Fast Range using hardware multiplier (replaces Modulo - better randomness bias and much faster)
	// generating random value from [0 to 2] (instead of: uint32_t lut0_i3 = xorshift32(rng_state) % 3;)
	uint32_t lut0_i3 = (uint32_t)(((uint64_t)xorshift32(rng_state) * 3) >> 32);
	ind.routing[0] = (lut0_i3 << 15) | (2 << 10) | (1 << 5) | 0;

	//----------------------------------------------------------------------------------------------------
	// LUT 1: y1 = !x0
	ind.F_table[1] = 0x5555;
	// input hardcoded: I0=x0(0).
	// I1, I2, I3 random from (0, 1, 2, 3)
	uint32_t lut1_i1 = (uint32_t)(((uint64_t)xorshift32(rng_state) * 4) >> 32);
	uint32_t lut1_i2 = (uint32_t)(((uint64_t)xorshift32(rng_state) * 4) >> 32);
	uint32_t lut1_i3 = (uint32_t)(((uint64_t)xorshift32(rng_state) * 4) >> 32);
	ind.routing[1] = (lut1_i3 << 15) | (lut1_i2 << 10) | (lut1_i1 << 5) | 0;

	//-----------------------------------------------------------------------------------------------------
	// LUT 2: y2 = x0 & !x1
	ind.F_table[2] = 0x2222;
	// inputs hardcoded: I0=x0(0), I1=x1(1).
	// I2, I3 random from (0, 1, 2, 3, 4)
	uint32_t lut2_i2 = (uint32_t)(((uint64_t)xorshift32(rng_state) * 5) >> 32);
	uint32_t lut2_i3 = (uint32_t)(((uint64_t)xorshift32(rng_state) * 5) >> 32);
	ind.routing[2] = (lut2_i3 << 15) | (lut2_i2 << 10) | (1 << 5) | 0;

	//------------------------------------------------------------------------------------------------------
	// JUNK DNA (LUT 3 to 29) - random topology and logic
	for (i = 3; i < NUM_NODES; i++) {
		ind.F_table[i] = xorshift32(rng_state) & 0xFFFF;
		uint32_t route = 0;
		for (j = 0; j < 4; j++) {
			uint32_t max_source = NUM_INPUTS + i - 1;
			uint32_t random_source = (uint32_t)(((uint64_t)xorshift32(rng_state) * (max_source + 1)) >> 32);
			route |= (random_source << (j * 5));
		}
		ind.routing[i] = route;
	}

	// assigning external outputs(y0-y2) to first 3 LUTs (indices 3, 4, 5 - 0, 1, 2 after adding 3 external inputs)
	// y2 - 12-bit shift, y1 - 6-bit shift, y0 - no shift
	ind.outputs = (5 << 12) | (4 << 6) | 3;
	ind.fitness = 0;

	return ind;
}

// writing genotype into Avalon-MM registers.
void hw_write_individual(const Individual *ind) {
	int i;
	for (i = 0; i < NUM_NODES; i++) {
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, i * 4, ind->routing[i]);
	}
	for (i = 0; i < NUM_NODES; i++) {
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, (30 + i) * 4, ind->F_table[i]);
	}
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, 60 * 4, ind->outputs);
}


int hw_evaluate_individual(const Individual *ind) {
	hw_write_individual(ind);

	// sending restart_cmd to FSM to trigger evaluation
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, 61 * 4, 0x01);

	volatile uint32_t status = IORD_32DIRECT(CGP_WATCHDOG_BASE, 62 * 4);

	// extracting fitness from bits [12:8]
	return (int)((status >> 8) & 0x1F);
}

void mutate_individual(const Individual *parent, Individual *child, uint32_t *rng_state) {
	*child = *parent;
	int i, j;

	for (i = 0; i < NUM_NODES; i++) {
		// 1. Truth Table Mutation with set probability threshold
		if (xorshift32(rng_state) < MUTATION_TH_F) {
			child->F_table[i] = xorshift32(rng_state) & 0xFFFF;
		}

		// 2. Routing Mutation (Inputs I0, I1, I2, I3)
		for (j = 0; j < 4; j++) {
			if (xorshift32(rng_state) < MUTATION_TH_IN) {
				// for DAG ensuring
				uint32_t max_source = NUM_INPUTS + i - 1;

				// using Lemire's Fast Range instead of %(modulo) for generating random value from [0  to max_source]
				uint32_t random_source = (uint32_t)(((uint64_t)xorshift32(rng_state) * (max_source + 1)) >> 32);

				uint32_t shift = j * 5;
				uint32_t mask = ~(0x1F << shift); // 5 zeroed bits

				child->routing[i] = (child->routing[i] & mask) | (random_source << shift); //pasting mutated value
			}
		}
	}

	// 3. Outputs Mutation (y0, y1, y2)
	for (j = 0; j < NUM_OUTPUTS; j++) {
		if (xorshift32(rng_state) < MUTATION_TH_IN) {
			// using Lemire's Fast Range instead of %(modulo) for generating random value from [0  to NUM_NODES-1]
			uint32_t random_source = (uint32_t)(((uint64_t)xorshift32(rng_state) * NUM_NODES) >> 32) + NUM_INPUTS;
			uint32_t shift = j * 6;
			uint32_t mask = ~(0x3F << shift); //6 zeroed bits

			child->outputs = (child->outputs & mask) | (random_source << shift);
		}
	}
}

void print_netlist(const Individual *ind) {
	int active_nodes[NUM_NODES] = {0};
	int stack[NUM_NODES];
	int stack_ptr = 0;
	int i, j;

	// extracting Cone of Logic backwards from outputs
	for (j = 0; j < NUM_OUTPUTS; j++) {
		uint32_t src = (ind->outputs >> (j * 6)) & 0x3F;
		int node_idx = src - NUM_INPUTS;
		if (node_idx >= 0 && node_idx < NUM_NODES && !active_nodes[node_idx]) {
			active_nodes[node_idx] = 1;
			stack[stack_ptr++] = node_idx;
		}
	}
	while (stack_ptr > 0) {
		int curr = stack[--stack_ptr];
		uint32_t route = ind->routing[curr];
		for (j = 0; j < 4; j++) {
			uint32_t src = (route >> (j * 5)) & 0x1F;
			if (src >= NUM_INPUTS) {
				int node_idx = src - NUM_INPUTS;
				if (node_idx < NUM_NODES && !active_nodes[node_idx]) {
					active_nodes[node_idx] = 1;
					stack[stack_ptr++] = node_idx;
				}
			}
		}
	}

	printf("\n--------------- EXTRACTED CGP NETLIST (DAG) ---------------------\n");
	const char* out_names[3] = {"y0", "y1", "y2"};

	printf("[EXTERNAL NODES]\n");
	for (j = 0; j < NUM_OUTPUTS; j++) {
		uint32_t src = (ind->outputs >> (j * 6)) & 0x3F;
		if (src < NUM_INPUTS)
			printf("  %s <=== Physical Input [x%d]\n", out_names[j], (int)src);
		else
			printf("  %s <=== Logic Gate  [LUT %02d]\n", out_names[j], (int)src - NUM_INPUTS);
	}

	printf("\n[ACTIVE LOGIC GATES]\n");
	int active_count = 0;
	for (i = 0; i < NUM_NODES; i++) {
		if (active_nodes[i]) {
			active_count++;
			printf("  [LUT %02d] :: F=0x%04X :: Inputs: ", i, (unsigned int)ind->F_table[i]);
			uint32_t route = ind->routing[i];
			for (j = 0; j < 4; j++) {
				uint32_t src = (route >> (j * 5)) & 0x1F;
				if (src < NUM_INPUTS) 	printf("(x%d)   ", (int)src);
				else					printf("(L%02d)  ", (int)src - NUM_INPUTS);
			}
			printf("\n");
		}
	}
	printf("---------------------------------------------------------------\n");
	printf("Utilization: %d/%d LUTs.\n", active_count, NUM_NODES);
	printf("---------------------------------------------------------------\n\n");
}
