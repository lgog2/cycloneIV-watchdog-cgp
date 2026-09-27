/*--------------------------------------------------------------------------------
 * file name: main.c
 * DESCRIPTION:
 * Verification of self-healing capabilities under PBI and Stuck-At fault injections
 * within the critical 333ms (16.6M cycles) deadline (signaled by hardware IRQ):
 *	1. Comparative Benchmark (Test 1): Nios II SW (1+4)-ES vs. HW (1+1)-ES
 *	2. Autonomous Hardware (1+1)-ES Cumulative Fault Tests:
 *		- Active-DAG targeting with window reset (Tests 2-3: IN SA0/1, PBI)
 *		- Continuous asynchronous full-matrix injection (Tests 4-7: PBI, IN, OUT, Mix)
 *--------------------------------------------------------------------------------
 */

#include <stdio.h>
#include <stdint.h>
#include "system.h"
#include "io.h"
#include "sys/alt_timestamp.h"
#include "sys/alt_stdio.h"
#include "sys/alt_irq.h"
#include <unistd.h> // for usleep()

#define NUM_NODES 30
#define NUM_INPUTS 3
#define NUM_OUTPUTS 3
#define EXPECTED_SEED_FITNESS 24
#define LAMBDA 4

// Register Map
#define ADDR_CONF_ROUTING	0
#define ADDR_CONF_F			30
#define ADDR_CONF_OUT		60
#define ADDR_CTRL			61
#define ADDR_STATUS			62
#define ADDR_FAULT_BASE		64
#define ADDR_LAST_REPAIR	90
#define ADDR_LIVE_GENS		91
#define ADDR_PRNG_SEED_L	100
#define ADDR_PRNG_SEED_H	101

// Control Register Flags (ADDR_CTRL)
#define CMD_RESTART			0x01 // Bit 0 -Hard Soft-Reset (FSM goes to ST_INIT)
#define CMD_PRNG_STEP		0x02 // Bit 1
#define CMD_LOAD_CONF		0x04 // Bit 2
#define CMD_EVO_DISABLE		0x08 // Bit 3
#define CMD_RESET_3HZ		0x10 // Bit 4
#define CMD_LOAD_SEED		0x20 // Bit 5


#define EMPTY				0x00000000

// Theoretical (1+1-ES): 66 cycles (8 test vectors * 8 cycles settling + 2 FSM overhead),
#define HW_CYCLES_PER_GEN	67 //confirmed empirically in run_hardware_evolution()
// defines number of bits flipped by LUT truth table mutation
#define MAX_BITS_TO_FLIP	16

// Probability thresholds for Software Mutation
// Xorshift space: 0 to 4294967295 (2^32 - 1)
#define MUTATION_TH_F  141733920UL	// ~3.3% of 2^32
#define MUTATION_TH_IN 34359738UL	// ~0.8% of 2^32

// Flag set in ISR
// meaning: 0.33s time window ended with system not fully funtional
volatile int irq_flag = 0;
volatile uint32_t exact_irq_timestamp = 0;

// genotype [NUM_NODES * [F, in0, in1, in2, in3], out0, out1, out2]
// maps directly to VRC hardware registers over Avalon-MM
typedef struct {
	uint32_t routing[NUM_NODES];	// 20 LSBs used (4 inputs x 5 bits; I0 -bits 4-0)
	uint32_t F_table[NUM_NODES];	// 16 LSBs used (Truth table)
	uint32_t outputs;				// 18 LSBs used (3 outputs x 6 bits; Y0 -bits 5-0)
	int fitness;
} Individual;

// 32-bit PRNG (George Marsaglia, 2003)
static inline uint32_t xorshift32(uint32_t *state) {
	uint32_t x = *state;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	*state = x;
	return x;
}

// ISR - Interrupt Service Routine
static void panic_interrupt_isr(void* context) {
	exact_irq_timestamp = (uint32_t)alt_timestamp();
	irq_flag = 1;
	// disabling interrupts
	alt_ic_irq_disable(CGP_WATCHDOG_IRQ_INTERRUPT_CONTROLLER_ID, CGP_WATCHDOG_IRQ);
}

// Uploading dynamic expected truth table for hardware evaluation
void set_target_function(uint32_t pattern) {
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, 63 * 4, pattern);

	// Hardware read-back assertion
	uint32_t verification = IORD_32DIRECT(CGP_WATCHDOG_BASE, 63 * 4);
	if (verification != pattern) {
		printf("[FATAL] Oracle TMR update failed! Wrote: 0x%08X, Read: 0x%08X\n", (unsigned int)pattern, (unsigned int)verification);
	}
}

void load_seed_for_hw_prng(uint32_t low_part, uint32_t high_part) {

	IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_PRNG_SEED_L * 4, low_part);
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_PRNG_SEED_H * 4, high_part);
	// loading and disabling hardware evolution mode
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_LOAD_SEED | CMD_EVO_DISABLE);
}

// Removing all NIOS-injected faults
void heal_all_faults() {
	int i;
	for(i = 0; i < NUM_NODES; i++) {
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, (ADDR_FAULT_BASE + i) * 4, EMPTY);
	}
}

// Fault injection (SPBI/MPBI + Stuck-At)
// sa_en / sa_val -> bit 4: OUT, bit 3: I3, bit 2: I2, bit 1: I1, bit 0: I0
void inject_fault(uint8_t lut_index, uint16_t pbi_mask, uint8_t sa_en, uint8_t sa_val) {

	if (lut_index >= NUM_NODES) return;

	// composition of the 32-bit fault word mapped to RTL decoder logic
	uint32_t fault_word = ((uint32_t)pbi_mask << 16) | ((uint32_t)(sa_val & 0x1F) << 8) | (sa_en & 0x1F);

	IOWR_32DIRECT(CGP_WATCHDOG_BASE, (ADDR_FAULT_BASE + lut_index) * 4, fault_word);
}

// writing genotype into Avalon-MM registers
void write_shadow_registers(const Individual *ind) {
	int i;
	for (i = 0; i < NUM_NODES; i++) {
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, (ADDR_CONF_ROUTING + i) * 4, ind->routing[i]);
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, (ADDR_CONF_F + i) * 4, ind->F_table[i]);
	}
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CONF_OUT * 4, ind->outputs);
}

void evaluate_individual(Individual *ind) {
	write_shadow_registers(ind);

	// loading from configuration from shadow registers
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_LOAD_CONF | CMD_EVO_DISABLE);

	volatile uint32_t status = IORD_32DIRECT(CGP_WATCHDOG_BASE, 62 * 4);

	// extracting fitness from bits [12:8]
	ind->fitness = (int)((status >> 8) & 0x1F);
}

void mutate_individual(const Individual *parent, Individual *child, uint32_t *rng_state) {
	*child = *parent;
	int i, j;

	for (i = 0; i < NUM_NODES; i++) {
		// Truth Table Mutation with set probability threshold
		if (xorshift32(rng_state) < MUTATION_TH_F) {

#if MAX_BITS_TO_FLIP > 0
			uint16_t bit_mask = 0;
			uint32_t bits_to_flip = (uint32_t)(((uint64_t)xorshift32(rng_state) * MAX_BITS_TO_FLIP) >> 32) + 1;

			for (uint32_t b = 0; b < bits_to_flip; b++) {
				uint32_t bit_pos = (uint32_t)(((uint64_t)xorshift32(rng_state) * 16) >> 32);
				bit_mask ^= (1 << bit_pos);
			}
			child->F_table[i] ^= bit_mask;
#else
			// Full Word Replacement
			child->F_table[i] = xorshift32(rng_state) & 0xFFFF;
#endif

		}

		// Routing Mutation (Inputs I0, I1, I2, I3)
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

	// Outputs Mutation (y0, y1, y2)
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


// reading current configuration
Individual read_hardware_individual() {
	Individual ind;
	int i;
	// routing for inputs
	for (i = 0; i < NUM_NODES; i++) {
		ind.routing[i] = IORD_32DIRECT(CGP_WATCHDOG_BASE, (ADDR_CONF_ROUTING + i) * 4);
	}
	// truth table
	for (int i = 0; i < NUM_NODES; i++) {
		ind.F_table[i] = (uint16_t)IORD_32DIRECT(CGP_WATCHDOG_BASE, (ADDR_CONF_F + i) * 4);
	}

	// outputs routing
	// y0(5:0), y1(11:6), y2(17:12)
	ind.outputs = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CONF_OUT * 4);

	return ind;
}

/*
 * Determining if the 16-bit truth table (F) logically depends on a specific input (in_idx)
 * by splitting the 16-bit truth table into two halves:
 * one where the target input is 1 (F|x=1), and one where it is 0 (F|x=0).
 * If (F|x=1 XOR F|x=0) != 0, the output state logically depends on this specific input.
 * */
int is_input_logically_active(uint16_t F, uint8_t in_idx) {
 /*----------------------------
	-- |    INPUTS...|| TRUTH |
	-- | I3 I2 I1 I0 || TABLE |
	-- ------------------------
	-- |  0  0  0  0 ||   x   |
	-- |  0  0  0  1 ||   x   |
	-- |  0  0  1  0 ||   x   |
	-- |  0  0  1  1 ||   x   |
	-- |  0  1  0  0 ||   x   |
	-- |  0  1  0  1 ||   x   |
	-- |  0  1  1  0 ||   x   |
	-- |  0  1  1  1 ||   x   |
	-- ------------------------
	-- |  1  0  0  0 ||   x   |
	-- |  1  0  0  1 ||   x   |
	-- |  1  0  1  0 ||   x   |
	-- |  1  0  1  1 ||   x   |
	-- |  1  1  0  0 ||   x   |
	-- |  1  1  0  1 ||   x   |
	-- |  1  1  1  0 ||   x   |
	-- |  1  1  1  1 ||   x   |
	---------------------------
 */
	switch (in_idx) {
		case 0:
			// I0 toggles every single bit (0, 1, 0, 1...).
			// Mask 0xAAAA (1010101010101010) extracts all truth table bits where I0 = 1.
			// We shift these bits right by 1 to align them with the I0 = 0 positions.
			// Mask 0x5555 (0101010101010101) extracts all truth table bits where I0 = 0.
			// If the aligned halves differ, the logical output relies on I0.
			return ((F & 0xAAAA) >> 1) != (F & 0x5555);
		case 1:
			// I1 toggles every 2 bits (00, 11, 00, 11...).
			// Mask 0xCCCC (1100110011001100) extracts bits where I1 = 1.
			// Shift right by 2 to align with the I1 = 0 positions.
			// Mask 0x3333 (0011...) extracts bits where I1 = 0.
			return ((F & 0xCCCC) >> 2) != (F & 0x3333);
		case 2:
			// I2 toggles every 4 bits (0000, 1111, 0000, 1111...).
			// Mask 0xF0F0 (1111000011110000) extracts bits where I2 = 1.
			// Shift right by 4 to align with the I2 = 0 positions.
			// Mask 0x0F0F (0000111100001111) extracts bits where I2 = 0.
			return ((F & 0xF0F0) >> 4) != (F & 0x0F0F);
		case 3:
			// I3 toggles every 8 bits (splitting the table into two bytes).
			// Mask 0xFF00 extracts the upper byte where I3 = 1.
			// Shift right by 8 to align with the lower byte.
			// Mask 0x00FF extracts the lower byte where I3 = 0.
			return ((F & 0xFF00) >> 8) != (F & 0x00FF);
		default:
			return 0;
	}
}

void extract_active_nodes(const Individual *ind, int *active_nodes, int logical_mode) {
	int stack[NUM_NODES];
	int stack_ptr = 0;
	int i;

	for (i = 0; i < NUM_NODES; i++) {
		active_nodes[i] = 0;
	}

	// Extracting Cone of Logic backwards from outputs
	for (i = 0; i < NUM_OUTPUTS; i++) {
		uint32_t src = (ind->outputs >> (i * 6)) & 0x3F;
		int node_idx = src - NUM_INPUTS;
		if (node_idx >= 0 && node_idx < NUM_NODES && !active_nodes[node_idx]) {
			active_nodes[node_idx] = 1;
			stack[stack_ptr++] = node_idx;
		}
	}

	while (stack_ptr > 0) {
		int curr = stack[--stack_ptr];
		uint32_t route = ind->routing[curr];
		uint16_t F = (uint16_t)ind->F_table[curr];

		for (i = 0; i < 4; i++) {
			if (!logical_mode || is_input_logically_active(F, i)) {
				uint32_t src = (route >> (i * 5)) & 0x1F;
				if (src >= NUM_INPUTS) {
					int node_idx = src - NUM_INPUTS;
					if (node_idx < NUM_NODES && !active_nodes[node_idx]) {
						active_nodes[node_idx] = 1;
						stack[stack_ptr++] = node_idx;
					}
				}
			}
		}
	}
}

void print_netlist(const Individual *ind, int logical_mode) {

	int active_nodes[NUM_NODES] = {0};

	extract_active_nodes(ind, active_nodes, logical_mode);

	if (logical_mode) {
		printf("\n--------------- EXTRACTED LOGICAL NETLIST (DAG) ---------------------\n");
	} else {
		printf("\n--------------- EXTRACTED STRUCTURAL NETLIST (DAG) ---------------------\n");
	}
	const char* out_names[3] = {"y0", "y1", "y2"};

	int i, j;

	printf("[EXTERNAL NODES]\n");
	for (i = 0; i < NUM_OUTPUTS; i++) {
		uint32_t src = (ind->outputs >> (i * 6)) & 0x3F;
		if (src < NUM_INPUTS)
			printf("  %s <=== Physical Input [x%d]\n", out_names[i], (int)src);
		else
			printf("  %s <=== Logic Gate  [LUT %02d]\n", out_names[i], (int)src - NUM_INPUTS);
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

				if (logical_mode && !is_input_logically_active((uint16_t)ind->F_table[i], j)) {
		printf("(--)   ");
				} else {
					if (src < NUM_INPUTS) {
						printf("(x%d)   ", (int)src);
					} else {
						printf("(L%02d)  ", (int)src - NUM_INPUTS);
					}
				}
			}
			printf("\n");
		}
	}
	printf("---------------------------------------------------------------\n");
	printf("Utilization: %d/%d LUTs.\n", active_count, NUM_NODES);
	printf("---------------------------------------------------------------\n\n");
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


void run_software_evolution(Individual parent, uint32_t *rng_state) {

	irq_flag = 0;
	// Re-enabling interrupts in case a recent Interrupt Service Routine disabled them.
	alt_ic_irq_enable(CGP_WATCHDOG_IRQ_INTERRUPT_CONTROLLER_ID, CGP_WATCHDOG_IRQ);

	volatile uint32_t status = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_STATUS * 4);
	parent.fitness = (int)((status >> 8) & 0x1F);

	alt_putstr("\nSoftware (1+4)-ES\n");

	if (parent.fitness == EXPECTED_SEED_FITNESS) {
		alt_putstr("Fitness is still 24. Skipping evolution.\n");
		return;
	}

	printf("\nFitness dropped to %d. Starting (1+4)-ES evolution.\n", parent.fitness);

	//reseting 3hz generator timer
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_EVO_DISABLE | CMD_RESET_3HZ);
	// Reset 32-bit hardware timer to prevent 85s overflow freezing
	alt_timestamp_start();
	uint32_t time_start = (uint32_t)alt_timestamp();

	int generation = 0;

	while (parent.fitness < EXPECTED_SEED_FITNESS) {
		generation++;
		Individual best_child;
		best_child.fitness = -1;

		int i;
		for (i = 0; i < LAMBDA; i++) {
			Individual child;
			mutate_individual(&parent, &child, rng_state);

			evaluate_individual(&child);

			if (child.fitness > best_child.fitness) {
				best_child = child;
			}

			if (child.fitness == EXPECTED_SEED_FITNESS) break;
		}

		if (best_child.fitness >= parent.fitness) {
			parent = best_child;
		}
	}

	uint32_t time_end = (uint32_t)alt_timestamp();
	uint32_t cycles_elapsed = time_end - time_start;
	uint32_t cycles_per_gen = cycles_elapsed/generation;

	printf("\n[SUCCESS] Max fitness achieved in Generation %d!\n", generation);
	printf("Time taken: %lu clock cycles | ~%lu us\n", cycles_elapsed, cycles_elapsed / 50);
	if (generation > 0) printf("%lu clock cycles per generation | ~%lu us\n", cycles_per_gen, cycles_per_gen / 50);
	if (irq_flag) printf("WARNING: Repair time exceeded 333ms. System used FAIL-SAFE override during repair.\n");

	print_netlist(&parent, 0);
	print_netlist(&parent, 1);
}

//rng_state arg only for compatibility with run_independent_faults_tests() signature
void run_hardware_evolution(Individual parent, uint32_t *dummy) {
	irq_flag = 0;
	// Re-enabling interrupts in case a recent Interrupt Service Routine disabled them.
	alt_ic_irq_enable(CGP_WATCHDOG_IRQ_INTERRUPT_CONTROLLER_ID, CGP_WATCHDOG_IRQ);

	volatile uint32_t status = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_STATUS * 4);
	int base_fitness = (int)((status >> 8) & 0x1F);

	alt_putstr("\nHardware (1+1)-ES\n");

	if (base_fitness == EXPECTED_SEED_FITNESS) {
		alt_putstr("Fitness is still 24. Skipping evolution.\n");
		return;
	}

	printf("\nFitness dropped to %d. Starting (1+1)-ES evolution.\n", base_fitness);

	uint32_t time_start = (uint32_t)alt_timestamp();

	// resets 3hz timer and zeroes CMD_EVO_DISABLE - enabling default hardware evolution
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_RESET_3HZ | CMD_RESTART);

	// polling the status register until hardware evolution restores fitness
	uint32_t fitness;
	do {
		status = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_STATUS * 4);
		fitness = (status >> 8) & 0x1F;
	} while(fitness < EXPECTED_SEED_FITNESS);

	uint32_t time_end = (uint32_t)alt_timestamp();
	uint32_t cycles_elapsed = time_end - time_start;
	// reading generation cost from the hardware register
	uint32_t generation = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_LAST_REPAIR * 4);

	uint32_t cycles_per_gen = cycles_elapsed/generation;

	printf("\n[SUCCESS] Max fitness achieved in Generation %lu!\n", generation);
	printf("Time taken: %lu clock cycles | ~%lu us\n", cycles_elapsed, cycles_elapsed / 50);
	if (generation > 0) printf("%lu clock cycles per generation | ~%lu us\n", cycles_per_gen, cycles_per_gen / 50);
	if (irq_flag) printf("WARNING: Repair time exceeded 333ms. System used FAIL-SAFE override during repair.\n");

	parent = read_hardware_individual();

	print_netlist(&parent, 0);
	print_netlist(&parent, 1);
}

void run_independent_faults_tests(void(*evolution_func)(Individual, uint32_t*), Individual ind)
{
	alt_putstr("\n\n========================= BASELINE ==============================\n");
	print_netlist(&ind, 0);
	print_netlist(&ind, 1);

	uint32_t rng_state = 0x12345678;

	const int NUM_TESTS = 3;
	int current_test = 0;

	while (1) {
		heal_all_faults();
		// loads and evaluates individual autoamtically disabling hardware evolution mode
		evaluate_individual(&ind);


		alt_putstr("\n\n======================================================\n");
		printf("--- Initiating test %d ---\n", current_test + 1);
		alt_putstr("======================================================\n");

		// reseting 3hz generator timer and FSM
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_EVO_DISABLE | CMD_RESET_3HZ | CMD_RESTART);

		if (current_test == 0) {
			alt_putstr("Output of LUT 0 - Stuck-At-0\n");
			inject_fault(0, 0x0000, 0x10, 0x00);
		} else if (current_test == 1) {
			alt_putstr("I0 of LUT 1 - Stuck-At-1 \n");
			inject_fault(1, 0x0000, 0x01, 0x01);
		} else if (current_test == 2) {
			alt_putstr("LUT 0, 1, 2 - MPBI.\nFull bitwise negation of truth table of LUT 0\nNegation of even-indexed bits in truth table of LUT 1\nNegation of odd-indexed bits in truth table 2\n");
			inject_fault(0, 0xFFFF, 0x00, 0x00); // Full bitwise negation of truth table 0
			inject_fault(1, 0x5555, 0x00, 0x00); // Negation of even-indexed bits in truth table 1
			inject_fault(2, 0xAAAA, 0x00, 0x00); // Negation of odd-indexed bits in truth table 2
		}

		// delaying start of evolution to give time for one more evaluation loop (min 8x8 + 2 = 66 cycles
		// 5us gives 250 cycles at 50MHz
		usleep(5);

		// executing evolution
		(*evolution_func)(ind, &rng_state);

		current_test++;

		if (current_test >= NUM_TESTS) break;

		alt_putstr("Waiting 3 seconds before next test.\n\n");
		usleep(3000000);
	}

}

void run_comparative_benchmark(const Individual ind)
{
	// disabling hardware autohealing
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, 61 * 4, CMD_EVO_DISABLE | CMD_RESTART);

	alt_putstr("\n\n\n==================================================================\n");
	alt_putstr("\n==================================================================\n");
	alt_putstr("[COMPARATIVE FAULT INJECTION BENCHMARK: SW (1+4) vs HW (1+1)]\n");
	alt_putstr("Executing identical 3 INDEPENDENT fault scenarios.\n");
	alt_putstr("Faults DO NOT accumulate; system resets and heals between strikes:\n");
	alt_putstr("  1. Output of LUT 0 - Stuck-At-0\n");
	alt_putstr("  2. Input 0 of LUT 1 - Stuck-At-1\n");
	alt_putstr("  3. LUT 0, 1, 2 - Multiple Permanent Bit Inversion (MPBI)\n");
	alt_putstr("Execution sequence: Phase 1 (Software 1+4) -> Phase 2 (Hardware 1+1)\n");
	alt_putstr("===================================================================\n");
	alt_putstr("\n==================================================================\n\n");

	alt_putstr("--- [PHASE 1] Software Evolution from NIOS (ES 1+4) ---\n");

	run_independent_faults_tests(run_software_evolution, ind);

	alt_putstr("--- [PHASE 2]Hardware Evolution (ES 1+1) ---\n");

	//load_seed_for_hw_prng(0x12345678, 0x9ABCDEF0);
	load_seed_for_hw_prng(0x1, 0x0);

	run_independent_faults_tests(run_hardware_evolution, ind);
}

void run_cumulative_routing_test(Individual ind, uint32_t *rng_state)
{
	alt_putstr("\n\n===============================================================\n");
	alt_putstr("CUMULATIVE ROUTING FAULTS (DEATHMARCH) - HARDWARE AUTO-HEALING\n");
	alt_putstr("- cumulative Stuck-At faults of LUTs inputs only.\n");
	alt_putstr("- targeting only active logic paths.\n");
	alt_putstr("- each new fault resets 3Hz time window.\n");
	alt_putstr("- test ends if evolution wont find new configuration in time window\n");
	alt_putstr("  or all LUT inputs in active logic paths are damaged.\n");
	alt_putstr("==================================================================\n");

	alt_putstr("\n\n========================= BASELINE ==============================\n");
	print_netlist(&ind, 0);
	print_netlist(&ind, 1);

	// Arrays tracking cumulative Stuck-At faults for each of the 30 nodes (LUTs)
	// Each node has 5 bits [OUT, I3, I2, I1, I0] for SA_EN and for SA_VAL (details in "consts_pkg.vhd")
	uint8_t current_sa_en[NUM_NODES] = {0};
	uint8_t current_sa_val[NUM_NODES] = {0};

	int total_faults = 0;
	int silent_faults = 0;

	Individual last_working_ind = ind;
	//clearing irq flag and enabling interrupts in case a recent Interrupt Service Routine disabled them.
	irq_flag = 0;
	alt_ic_irq_enable(CGP_WATCHDOG_IRQ_INTERRUPT_CONTROLLER_ID, CGP_WATCHDOG_IRQ);

	while (1) {
		int active_nodes[NUM_NODES];
		extract_active_nodes(&ind, active_nodes, 1);


		typedef struct {
			uint8_t lut;
			uint8_t input_idx; // 0 to 3 (I0-I3)
		} Target;

		// array of available, undamaged targets
		Target valid_targets[NUM_NODES * 4];
		int num_targets = 0;
		int i, j;

		for (i = 0; i < NUM_NODES; i++) {
			if (active_nodes[i]) {
				uint16_t F = (uint16_t)ind.F_table[i];
				for (j = 0; j < 4; j++) {
					// Checking bit in 'current_sa_en' (left shift by 'j')
					if (is_input_logically_active(F, j) && ((current_sa_en[i] & (1 << j)) == 0)) {
						valid_targets[num_targets].lut = i;
						valid_targets[num_targets].input_idx = j;
						num_targets++;
					}
				}
			}
		}

		if (num_targets == 0) {
			printf("\n[END] All active paths saturated with faults. Matrix capacity exhausted.\n");
			printf("Number of routing faults: %d (%d silent).\n", total_faults, silent_faults);
			break;
		}

		// Drawing target and fault type (Stuck-At-0 or Stuck-At-1)(from 0 to num_targets-1)
		uint32_t target_idx = (uint32_t)(((uint64_t)xorshift32(rng_state) * num_targets) >> 32);
		Target t = valid_targets[target_idx];

		uint8_t is_stuck_at_1 = xorshift32(rng_state) & 0x1;

		// Updating cumulative faults matrix
		current_sa_en[t.lut] |= (1 << t.input_idx);
		if (is_stuck_at_1) {
			current_sa_val[t.lut] |= (1 << t.input_idx);
		} else {
			current_sa_val[t.lut] &= ~(1 << t.input_idx); // forcing 0
		}

		total_faults++;
		printf("\n--- Fault Strike #%d ---\n", total_faults);
		printf("Injecting Stuck-At-%d into LUT %d, Input I%d\n", is_stuck_at_1, t.lut, t.input_idx);

		// disablinng auto-evolution before fault injection
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_EVO_DISABLE | CMD_RESET_3HZ);

		// Injection of updated cumulative faults masks to a specific LUT
		inject_fault(t.lut, 0x0000, current_sa_en[t.lut], current_sa_val[t.lut]);

		IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_EVO_DISABLE | CMD_RESTART);

		// giving time for evaluation (5 us ~ 250 clock cycles at 50 MHz)
		usleep(5);

		// Reading stable fitness
		volatile uint32_t status = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_STATUS * 4);
		int current_fit = (status >> 8) & 0x1F;

		if (current_fit == EXPECTED_SEED_FITNESS) {
			silent_faults++;
			printf("Silent Fault! The evolutionary topology masked the fault (Fitness still 24).\n");
			continue;
		}

		printf("Fitness dropped to %d. Starting (1+1)-ES evolution.\n", current_fit);

		// Starts evolution and zeroes 3Hz timer
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_RESET_3HZ | CMD_RESTART); // Starts evolution and zeroes 3Hz timer

		// Active Polling
		do {
			status = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_STATUS * 4);
			current_fit = (status >> 8) & 0x1F;
			if (irq_flag) {
				break;
			}
		} while (current_fit < EXPECTED_SEED_FITNESS);

		if (irq_flag) {
			printf("\n[END] System failed to restore logic within the 333ms deadline!\n");
			printf("System survived %d cumulative routing faults before critical failure.\n", total_faults - 1);
			printf("( %d silent )\n", silent_faults);
			break;
		}

		// Reading number of generations from HW register
		uint32_t gens = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_LAST_REPAIR * 4);

		// Deterministic hardware cycles calculation (1 Generation = 67 sys clock cycles at 50MHz)
		uint32_t hw_cycles = gens * HW_CYCLES_PER_GEN;

		printf("Repaired in %lu generations (Time: %lu cycles | ~%lu us).\n", gens, hw_cycles, hw_cycles / 50);

		// Fetching new matrix layout for next faults
		ind = read_hardware_individual();

		last_working_ind = ind;
	}

	alt_putstr("\n\n================== LAST WORKING CONFIGURATION =======================\n");
	print_netlist(&last_working_ind, 0);
	print_netlist(&last_working_ind, 1);
}

void run_cumulative_pbi_test(Individual ind, uint32_t *rng_state)
{
	alt_putstr("\n\n===============================================================\n");
	alt_putstr("CUMULATIVE LOGIC FAULTS (PBI) - HARDWARE AUTO-HEALING\n");
	alt_putstr("- cumulative Permanent Bit Inversions of LUTs Truth Tables single bits.\n");
	alt_putstr("- targeting only active logic paths.\n");
	alt_putstr("- each new fault resets 3Hz time window.\n");
	alt_putstr("- test ends if evolution wont find new configuration in time window.\n");
	alt_putstr("  or all bits in Truth Tables of LUTs in active logic paths are damaged.\n");
	alt_putstr("==================================================================\n");

	alt_putstr("\n\n========================= BASELINE ==============================\n");
	print_netlist(&ind, 0);
	print_netlist(&ind, 1);

	// Array tracking cumulative PBI mask for each of the 30 nodes (LUTs)
	uint16_t current_pbi_mask[NUM_NODES] = {0};
	int total_faults = 0;
	int silent_faults = 0;

	Individual last_working_ind = ind;
	//clearing irq flag and enabling interrupts in case a recent Interrupt Service Routine disabled them.
	irq_flag = 0;
	alt_ic_irq_enable(CGP_WATCHDOG_IRQ_INTERRUPT_CONTROLLER_ID, CGP_WATCHDOG_IRQ);

	while (1) {
		int active_nodes[NUM_NODES];
		extract_active_nodes(&ind, active_nodes, 1);

		typedef struct {
			uint8_t lut;
			uint8_t bit_idx; // 0 to 15 (F-table bits)
		} Target;

		// array of available, undamaged targets
		Target valid_targets[NUM_NODES * 16];
		int num_targets = 0;
		int i, j;

		for (i = 0; i < NUM_NODES; i++) {
			if (active_nodes[i]) {
				for (j = 0; j < 16; j++) {
					// Check if this specific bit is not yet inverted
					if ((current_pbi_mask[i] & (1 << j)) == 0) {
						valid_targets[num_targets].lut = i;
						valid_targets[num_targets].bit_idx = j;
						num_targets++;
					}
				}
			}
		}

		if (num_targets == 0) {
			printf("\n[END OF TEST] All active LUTs logic bits are completely inverted. Capacity exhausted.\n");
			printf("Number of faults: %d (%d silent).\n", total_faults, silent_faults);
			break;
		}

		// Drawing target LUT and specific bit
		uint32_t target_idx = (uint32_t)(((uint64_t)xorshift32(rng_state) * num_targets) >> 32);
		Target t = valid_targets[target_idx];

		// Cumulative flip of the selected truth-table bit
		current_pbi_mask[t.lut] |= (1 << t.bit_idx);

		total_faults++;
		printf("\n--- Fault Strike #%d ---\n", total_faults);
		printf("Injecting Single Permanent Bit Inversion (Bit %d) into LUT %d\n", t.bit_idx, t.lut);

		// disablinng auto-evolution before fault injection
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_EVO_DISABLE | CMD_RESET_3HZ);

		// Injection of updated cumulative faults masks to a specific LUT truth table
		inject_fault(t.lut, current_pbi_mask[t.lut], 0x00, 0x00);

		IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_EVO_DISABLE | CMD_RESTART);

		// giving time for evaluation (5 us ~ 250 clock cycles at 50 MHz)
		usleep(5);

		// Reading stable fitness
		volatile uint32_t status = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_STATUS * 4);
		int current_fit = (status >> 8) & 0x1F;

		if (current_fit == EXPECTED_SEED_FITNESS) {
			silent_faults++;
			printf("Silent Fault! Bit inversion did not break the current logic flow (Fitness still 24).\n");
			continue;
		}

		printf("Fitness dropped to %d. Starting (1+1)-ES cumulative evolution.\n", current_fit);

		// Starts evolution, zeroes 3Hz timer and restarts FSM
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_RESET_3HZ | CMD_RESTART);

		// Active Polling
		do {
			status = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_STATUS * 4);
			current_fit = (status >> 8) & 0x1F;
			if (irq_flag) {
				break;
			}
		} while (current_fit < EXPECTED_SEED_FITNESS);

		if (irq_flag) {
			printf("\n[END] System failed to restore logic within the 333ms deadline!\n");
			printf("System survived %d cumulative PBI faults before critical failure.\n", total_faults - 1);
			printf("( %d silent )\n", silent_faults);
			break;
		}
		// Reading number of generations from HW register
		uint32_t gens = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_LAST_REPAIR * 4);

		// Deterministic hardware cycles calculation (1 Generation = 67 sys clock cycles at 50MHz)
		uint32_t hw_cycles = gens * HW_CYCLES_PER_GEN;

		printf("Repaired in %lu generations (Time: %lu cycles | ~%lu us).\n", gens, hw_cycles, hw_cycles / 50);

		ind = read_hardware_individual();

		last_working_ind = ind;
	}

	alt_putstr("\n\n================== LAST WORKING CONFIGURATION =======================\n");
	print_netlist(&last_working_ind, 0);
	print_netlist(&last_working_ind, 1);

}

void run_continuous_asynchronous_faults_test(Individual ind, uint32_t *rng_state, uint8_t test_mode)
{
	//reset of SW/HW PRNG states for repeatability of results
	*rng_state = 0x12345678;
	load_seed_for_hw_prng(0x1, 0x0);

	alt_putstr("\n\n===============================================================\n");

	switch(test_mode) {
		case 0:
			alt_putstr("TEST 7: CONTINUOUS ASYNCHRONOUS FAULT INJECTION (GRACEFUL DEGRADATION)\n");
			alt_putstr("- Mode: FULL (MIX 16:4:1)\n");
			alt_putstr("- Injections: PBI, Input Stuck-At, and Output Stuck-At.\n");
			break;
		case 1:
			alt_putstr("TEST 4: CONTINUOUS ASYNCHRONOUS FAULT INJECTION (GRACEFUL DEGRADATION)\n");
			alt_putstr("- Mode: LOGIC DEGRADATION ONLY\n");
			alt_putstr("- Injections: Permanent Bit Inversions (PBI) of Truth Tables ONLY.\n");
			break;
		case 2:
			alt_putstr("TEST 5: CONTINUOUS ASYNCHRONOUS FAULT INJECTION (GRACEFUL DEGRADATION)\n");
			alt_putstr("- Mode: ROUTING DEGRADATION ONLY\n");
			alt_putstr("- Injections: Input Stuck-At-0 / Stuck-At-1 ONLY.\n");
			break;
		case 3:
			alt_putstr("TEST 6: CONTINUOUS ASYNCHRONOUS FAULT INJECTION (GRACEFUL DEGRADATION)\n");
			alt_putstr("- Mode: RAPID DEGRADATION\n");
			alt_putstr("- Injections: Output Stuck-At-0 / Stuck-At-1 ONLY (Node elimination).\n");
			break;
		default:
			alt_putstr("- Mode: UNKNOWN FAULT PROFILE\n");
			break;
	}
	alt_putstr("- Hardware evolution operates asynchronously; the 3Hz timer is never reset.\n");
	alt_putstr("- Evaluates system fitness and logs fatal capacity loss.\n");
	alt_putstr("  Test ends after 5.0s (~15 consecutive 333ms windows) of PANIC - state\n");
	alt_putstr("  where the system is unable to repair itself even for a moment.\n");
	alt_putstr("  (This enforces 5s of continuous SAFE OUT on capacitors, meaning 5s\n");
	alt_putstr("   without supervision for the watchdog-monitored device).\n");
	alt_putstr("==================================================================\n");

	alt_putstr("\n\n========================= BASELINE ==============================\n");
	print_netlist(&ind, 0);
	print_netlist(&ind, 1);

	uint16_t current_pbi_mask[NUM_NODES] = {0};
	uint8_t current_sa_en[NUM_NODES] = {0};
	uint8_t current_sa_val[NUM_NODES] = {0};

	heal_all_faults();
	// evaluate_individual() automatically disables hardware evolution mode
	evaluate_individual(&ind);

	int total_faults = 0;
	int injected_pbi = 0, injected_in = 0, injected_out = 0;

	uint32_t timer_freq = alt_timestamp_freq(); // 50 million for 50MHZ
	uint32_t injection_interval_cycles = (timer_freq / 1000) * 15; // 15 ms
	const uint32_t FIVE_SECONDS_CYCLES = timer_freq * 5;

	uint8_t in_panic = 0;
	uint32_t panic_start_time = 0;

	int faults_at_panic_start = 0;
	int pbi_at_panic_start = 0;
	int in_at_panic_start = 0;
	int out_at_panic_start = 0;

	uint8_t end_reason = 0; // 1: 5s PANIC timeout, 2: pool exhausted in PANIC, 3: pool saturated while system healthy

	// snapshot of last healed configuration
	Individual last_working_ind = ind;
	// Zero-overhead RAM telemetry buffer to prevent JTAG UART FIFO stalls during real-time injection
	typedef struct {
		uint8_t event_type; // 0: STRIKE, 1: PANIC_ENTER, 2: PANIC_EXIT
		uint8_t fault_cat;  // 0: PBI, 1: IN, 2: OUT
		uint8_t lut;
		uint8_t sub_idx;    // bit_idx or input_idx
		uint8_t sa_val;
		uint16_t strike_num;
		uint32_t recovery_ms;
	} TelemetryEvent;

	static TelemetryEvent event_log[700];
	int event_count = 0;


	// ========================================================================
	// PHYSICAL FAULT MODEL (16:4:1)
	// Total physical system capacity is 630 unique fault locations
	// (30*16 PBI + 30*4 IN + 30 OUT). Mapping:
	// Index 0-479: PBI, 480-599: IN Stuck-At, 600-629: OUT Stuck-At.
	// ========================================================================
	uint16_t fault_pool[630];
	uint32_t pool_size = 0;

	for (uint32_t i = 0; i < 630; i++) {
		if (test_mode == 0) { // mode 0: MIX 16:4:1
			fault_pool[pool_size++] = i;
		} else if (test_mode == 1 && i < 480) { // mode 1: only PBI
			fault_pool[pool_size++] = i;
		} else if (test_mode == 2 && i >= 480 && i < 600) { // mode 2: only IN
			fault_pool[pool_size++] = i;
		} else if (test_mode == 3 && i >= 600) { // mode 3: only OUT (PANIC kill)
			fault_pool[pool_size++] = i;
		}
	}
	printf("\n>>> INITIALIZING FAULT INJECTION TEST | POOL SIZE: %lu <<<\n", pool_size);
	//waiting for JTAG UART FIFO to drain
	usleep(50000);

	// Initializing evolution
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_RESET_3HZ | CMD_RESTART);
	irq_flag = 0;
	alt_ic_irq_enable(CGP_WATCHDOG_IRQ_INTERRUPT_CONTROLLER_ID, CGP_WATCHDOG_IRQ);

	alt_timestamp_start();

	uint32_t last_inject_time = (uint32_t)alt_timestamp();

	while (1) {
		if (irq_flag) {
			if (!in_panic) {
				//alt_putstr("\n[IRQ] 333ms Window exceeded! System entered PANIC.\n");
				in_panic = 1;
				panic_start_time = exact_irq_timestamp;

				if (event_count < 700) {
					event_log[event_count++].event_type = 1; // PANIC_ENTER
				}
			}

			// Polling fitness to check for recovery
			volatile uint32_t status = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_STATUS * 4);
			int current_fit = (status >> 8) & 0x1F;

			if (current_fit == EXPECTED_SEED_FITNESS) {
				uint32_t recovery_cycles = (uint32_t)alt_timestamp() - panic_start_time;
				uint32_t recovery_ms = recovery_cycles / (timer_freq / 1000);

				//printf("[RECOVERY] System exited PANIC after %lu msec!	Resuming...\n\n", recovery_ms);
				if (event_count < 700) {
					event_log[event_count].event_type = 2; // PANIC_EXIT
					event_log[event_count].recovery_ms = recovery_ms;
					event_count++;
				}
				in_panic = 0;
				irq_flag = 0;

				// System successfully healed all faults injected up to this recovery point
				last_working_ind = read_hardware_individual();

				faults_at_panic_start = total_faults;
				pbi_at_panic_start = injected_pbi;
				in_at_panic_start = injected_in;
				out_at_panic_start = injected_out;

				alt_ic_irq_enable(CGP_WATCHDOG_IRQ_INTERRUPT_CONTROLLER_ID, CGP_WATCHDOG_IRQ);
			} else {
				if (((uint32_t)alt_timestamp() - panic_start_time) >= FIVE_SECONDS_CYCLES) {
					end_reason = 1;//5s PANIC timeout
					break;
				}
			}
		}

		// Asynchronous Fault Injection
		uint32_t current_time = (uint32_t)alt_timestamp();
		if ((current_time - last_inject_time) >= injection_interval_cycles) {
			last_inject_time += injection_interval_cycles;

			volatile uint32_t status = IORD_32DIRECT(CGP_WATCHDOG_BASE, ADDR_STATUS * 4);
			int current_fit = (status >> 8) & 0x1F;

			if (current_fit == EXPECTED_SEED_FITNESS && !in_panic) {
				last_working_ind = read_hardware_individual();

				faults_at_panic_start = total_faults;
				pbi_at_panic_start = injected_pbi;
				in_at_panic_start = injected_in;
				out_at_panic_start = injected_out;
			}

			if (pool_size == 0) {
				if (in_panic) {
					end_reason = 2;//pool exhausted in PANIC
					break;
				} else if (current_fit == EXPECTED_SEED_FITNESS) {
					end_reason = 3;//pool saturated while system healthy
					break;
				}
				// Pool is empty, but circuit is currently broken (fitness < 24) and waiting
				// for either repair or the 333ms watchdog IRQ to trigger PANIC
				continue;
			}

			uint32_t random_idx = (uint32_t)(((uint64_t)xorshift32(rng_state) * pool_size) >> 32);
			uint16_t selected_fault = fault_pool[random_idx];

			// Fisher-Yates Pop: replace drawn item with the last one in the pool, then decrement the pool
			fault_pool[random_idx] = fault_pool[pool_size - 1];
			pool_size--;

			uint32_t target_lut;
			uint32_t fault_category;
			uint32_t target_bit = 0;
			uint32_t target_input = 0;
			uint8_t is_stuck_at_1 = xorshift32(rng_state) & 0x1;

			if (selected_fault < 480) {
				fault_category = 0; // PBI
				target_lut = selected_fault / 16;
				target_bit = selected_fault % 16;
				injected_pbi++;
				current_pbi_mask[target_lut] |= (1 << target_bit);
			} else if (selected_fault < 600) {
				fault_category = 1; // IN
				uint16_t offset = selected_fault - 480;
				target_lut = offset / 4;
				target_input = offset % 4;
				injected_in++;
				current_sa_en[target_lut] |= (1 << target_input);
				if (is_stuck_at_1) {
					current_sa_val[target_lut] |= (1 << target_input);
				} else {
					current_sa_val[target_lut] &= ~(1 << target_input);
				}
			} else {
				fault_category = 2; // OUT
				target_lut = selected_fault - 600;
				injected_out++;
				current_sa_en[target_lut] |= (1 << 4);
				if (is_stuck_at_1) {
					current_sa_val[target_lut] |= (1 << 4);
				} else {
					current_sa_val[target_lut] &= ~(1 << 4);
				}
			}

			// no EVO_DISABLE during Fault Injection - fault can hit durin evaluation
			inject_fault(target_lut, current_pbi_mask[target_lut], current_sa_en[target_lut], current_sa_val[target_lut]);

			total_faults++;
			if (event_count < 700) {
				event_log[event_count].event_type = 0; // STRIKE
				event_log[event_count].fault_cat = (uint8_t)fault_category;
				event_log[event_count].lut = (uint8_t)target_lut;
				event_log[event_count].sub_idx = (uint8_t)(fault_category == 0 ? target_bit : target_input);
				event_log[event_count].sa_val = is_stuck_at_1;
				event_log[event_count].strike_num = (uint16_t)total_faults;
				event_count++;
			}
		}
	}
	// log printing
	for (int i = 0; i < event_count; i++) {
		TelemetryEvent *ev = &event_log[i];
		if (ev->event_type == 0) {
			printf("--- Fault Strike #%u --- ", ev->strike_num);
			if (ev->fault_cat == 0) {
				printf("Injecting PBI (Bit %u) into LUT %u\n", ev->sub_idx, ev->lut);
			} else if (ev->fault_cat == 1) {
				printf("Injecting Input Stuck-At-%u into LUT %u, Input I%u\n", ev->sa_val, ev->lut, ev->sub_idx);
			} else {
				printf("Injecting Output Stuck-At-%u into LUT %u (Total LUT Dysfunction)\n", ev->sa_val, ev->lut);
			}
		} else if (ev->event_type == 1) {
			alt_putstr("\n[IRQ] 333ms Window exceeded! System entered PANIC.\n");
		} else if (ev->event_type == 2) {
			printf("[RECOVERY] System exited PANIC after %lu msec!    Resuming...\n\n", ev->recovery_ms);
		}
	}

	if (end_reason == 1) {
		alt_putstr("\n[END] System trapped in PANIC for 5.0 seconds without recovery.\n");
		printf("System absorbed %d UNIQUE asynchronous hard faults before capacity loss.\n", faults_at_panic_start);
		printf("Breakdown: [ %d PBI | %d IN | %d OUT ]\n", pbi_at_panic_start, in_at_panic_start, out_at_panic_start);
	} else if (end_reason == 2) {
		alt_putstr("\n[END] Pool exhausted while in PANIC\n");
		printf("System absorbed %d UNIQUE faults before capacity loss.\n", faults_at_panic_start);
		printf("Breakdown: [ %d PBI | %d IN | %d OUT ]\n", pbi_at_panic_start, in_at_panic_start, out_at_panic_start);
	} else if (end_reason == 3) {
		alt_putstr("\n[END] Active fault pool saturated. System survived maximum degradation.\n");
		printf("System successfully absorbed all %d faults.\n", total_faults);
		printf("Breakdown: [ %d PBI | %d IN | %d OUT ]\n", injected_pbi, injected_in, injected_out);
	}

	alt_putstr("\n\n=================== LAST WORKING CONFIGURATION ====================\n");
	print_netlist(&last_working_ind, 0);
	print_netlist(&last_working_ind, 1);
}

//helper function (no standard getchar avaiable)
char custom_getchar(void) {
	uint32_t data;
	do {
		// polling JTAG UART register (Avalon JTAG UART IP Core)
		data = IORD_32DIRECT(JTAG_UART_0_BASE, 0);
	} while ((data & 0x00008000) == 0); // Bit 15: RAVAIL (input present in FIFO)

	return (char)(data & 0xFF); // bits [7:0] - data (ASCII)
}


int main() {
	//registering Interrupt Service Routine
	int irq_status = alt_ic_isr_register(
		CGP_WATCHDOG_IRQ_INTERRUPT_CONTROLLER_ID,
		CGP_WATCHDOG_IRQ,
		panic_interrupt_isr,
		NULL,
		NULL
	);

	if (irq_status != 0) {
		printf("[FATAL] Interrupt Service Routine registering fault!\n");
		while(1);
	}

	// Initializing Timer for profiling (requires hardware timer syntetized)
	if (alt_timestamp_start() < 0) {
		alt_putstr("[WARN] Timer not found. Clock profiling disabled.\n");
	}

	// initializing TMR Target with Watchdog Pattern
	// combinations (Y2, Y1, Y0) from states 7 to 0 packed into a 24-bit payload.
	// 001_011_100_011_001_011_100_010 = 0x002E32E2
	alt_putstr("Configuring Hardware Reference Truth Table (TMR)...\n");
	set_target_function(0x002E32E2);

	uint32_t rng_state	= 0x12345678;
	Individual seed	= create_seed(&rng_state);

	while (1) {
		alt_putstr("\n\n=================================================================\n");
		alt_putstr(" Tests of repair capabilities under SPBI/MPBI and Stuck-At fault injections\n");
		alt_putstr("=====================================================================\n");
		alt_putstr("[1] Comparative Benchmark (SW 1+4 vs HW 1+1)\n");
		alt_putstr("[2] Cumulative Routing Faults Test (STA-0/STA-1 of LUTs inputs)\n");
		alt_putstr("[3] Cumulative Logic Faults Test (PBI of LUTs Truth Tables)\n");
		alt_putstr("--- CONTINUOUS ASYNCHRONOUS FAULT TESTS ---------------------\n");
		alt_putstr("[4] Logic Degradation Only (PBI)\n");
		alt_putstr("[5] Routing Degradation Only (Inputs Stuck-At)\n");
		alt_putstr("[6] Rapid Degradation (Outputs Stuck-At)\n");
		alt_putstr("[7] Full Model (Mix 16:4:1)\n");
		alt_putstr("---------------------------------------------------------------------\n");
		alt_putstr("Select test (1-7) and press Enter: ");

		char choice;
		do {
			choice = custom_getchar();
		} while (choice == '\n' || choice == '\r');


		rng_state = 0x12345678;
		load_seed_for_hw_prng(0x1, 0x0);
		heal_all_faults();
		// evaluate_individual() automatically disables hardware evolution mode
		evaluate_individual(&seed);

		if (seed.fitness != EXPECTED_SEED_FITNESS) {
			printf("[ERROR] SEED fitness %d. Logic is damaged.\nAborting.\n", seed.fitness);
			return 1;
		}

		switch (choice) {
			case '1':
				run_comparative_benchmark(seed);
				break;
			case '2':
				run_cumulative_routing_test(seed, &rng_state);
				break;
			case '3':
				run_cumulative_pbi_test(seed, &rng_state);
				break;
			case '4':
				//CONTINUOUS ASYNCHRONOUS FAULT TEST - PBI ONLY
				run_continuous_asynchronous_faults_test(seed, &rng_state, 1);
				break;
			case '5':
				//CONTINUOUS ASYNCHRONOUS FAULT TEST - INPUTS ONLY
				run_continuous_asynchronous_faults_test(seed, &rng_state, 2);
				break;
			case '6':
				//CONTINUOUS ASYNCHRONOUS FAULT TEST - OUTPUTS ONLY
				run_continuous_asynchronous_faults_test(seed, &rng_state, 3);
				break;
			case '7':
				//CONTINUOUS ASYNCHRONOUS FAULT TEST - MIX 16:4:1
				run_continuous_asynchronous_faults_test(seed, &rng_state, 0);
				break;
			default:
				alt_putstr("\nInvalid selection.\n");
				break;
		}
	}

	return 0;
}
