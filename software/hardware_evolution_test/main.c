/*--------------------------------------------------------------------------------
* file name: main.c
* DESCRIPTION:
*	Comparative Evolution Benchmark (Software vs. Hardware)
*	Evaluates Nios II-driven (1+4)-ES against autonomous hardware (1+1)-ES
*	repair capabilities under SPBI/MPBI and Stuck-At fault injections.
*	Demonstrates the orders-of-magnitude speed advantage of hardware evolution
*	in restoring system fitness within the critical 333ms (16M cycles) deadline.
* --------------------------------------------------------------------------------
*/

#include <stdio.h>
#include <stdint.h>//?
#include "system.h"
#include "io.h"//?
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

// Control Register Flags (ADDR_CTRL)
#define CMD_RESTART			0x01 // Hard Soft-Reset (FSM goes to ST_INIT)
#define CMD_PRNG_STEP		0x02
#define CMD_LOAD_CONF		0x04
#define CMD_EVO_DISABLE		0x08
#define CMD_RESET_3HZ		0x10

#define EMPTY				0x00000000

// Probability thresholds for Software Mutation
// Xorshift space: 0 to 4294967295 (2^32 - 1)
#define MUTATION_TH_F  141733920UL	// ~3.3% of 2^32
#define MUTATION_TH_IN 34359738UL	// ~0.8% of 2^32
#define ADDR_LIVE_GENS 91

// Flag set in ISR
// meaning: 0.33s time window ended with system not fully funtional
volatile int irq_flag = 0;

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
			child->F_table[i] = xorshift32(rng_state) & 0xFFFF;
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

	printf("\n[SUCCESS] Max fitness achieved in Generation %d!\n", generation);
	printf("Time taken: %lu clock cycles\n", cycles_elapsed);
	if (generation > 0) printf("%lu clock cycles per generation\n", cycles_elapsed/generation);
	if (irq_flag) printf("WARNING: Repair time exceeded 333ms. System used FAIL-SAFE override during repair.\n");

	print_netlist(&parent);
}


void run_hardware_evolution(Individual parent, uint32_t *rng_state) {
	irq_flag = 0;

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
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, ADDR_CTRL * 4, CMD_RESET_3HZ);

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

	printf("\n[SUCCESS] Max fitness achieved in Generation %lu!\n", generation);
	printf("Time taken: %lu clock cycles\n", cycles_elapsed);
	if (generation > 0) printf("%lu clock cycles per generation\n", cycles_elapsed/generation);
	if (irq_flag) printf("WARNING: Repair time exceeded 333ms. System used FAIL-SAFE override during repair.\n");

	parent = read_hardware_individual();

	print_netlist(&parent);
}


void run_tests(void(*evolution_func)(Individual, uint32_t*), Individual ind)
{
	// disabling hardware autohealing
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, 61 * 4, CMD_EVO_DISABLE | CMD_RESTART);

	uint32_t rng_state	= 0x12345678;
	heal_all_faults();
	evaluate_individual(&ind);

	if (ind.fitness != EXPECTED_SEED_FITNESS) {
		printf("[ERROR] SEED fitness %d. Logic is damaged.\nFreezing system.\n", ind.fitness);
		while(1);
	}
	const int NUM_TESTS = 3;
	int current_test = 0;

	while (1) {
		heal_all_faults();
		evaluate_individual(&ind);
		alt_putstr("\n\n======================================================\n");
		printf("--- Initiating test %d ---\n", current_test + 1);
		alt_putstr("======================================================\n");

		// reseting 3hz generator timer
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

		// executing evolution
		(*evolution_func)(ind, &rng_state);

		current_test++;

		if (current_test >= NUM_TESTS) break;

		alt_putstr("Waiting 3 seconds before next test.\n\n");
		usleep(3000000);
	}
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

	alt_putstr("=== TEST: Software Evolution from NIOS (4+1 ES) vs. Hardware Evolution (1+1 ES) ===\n");

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
	Individual parent	= create_seed(&rng_state);

	alt_putstr("\n\n========================= BASELINE ==============================\n");
	print_netlist(&parent);

	alt_putstr("\n==================================================================\n");
	alt_putstr("[COMPARATIVE FAULT INJECTION BENCHMARK: SW (1+4) vs HW (1+1)]\n");
	alt_putstr("Executing identical 3 INDEPENDENT fault scenarios.\n");
	alt_putstr("Faults DO NOT accumulate; system resets and heals between strikes:\n");
	alt_putstr("  1. Output of LUT 0 - Stuck-At-0\n");
	alt_putstr("  2. Input 0 of LUT 1 - Stuck-At-1\n");
	alt_putstr("  3. LUT 0, 1, 2 - Multiple Permanent Bit Inversion (MPBI)\n");
	alt_putstr("Execution sequence: Phase 1 (Software 4+1) -> Phase 2 (Hardware 1+1)\n");
	alt_putstr("==================================================================\n\n");

	alt_putstr("--- [PHASE 1] Software Evolution from NIOS (ES 4+1) ---\n");

	run_tests(run_software_evolution, parent);

	alt_putstr("--- [PHASE 2]Hardware Evolution (ES 1+1) ---\n");

	run_tests(run_hardware_evolution, parent);

	return 0;
}
