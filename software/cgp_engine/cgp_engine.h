/*--------------------------------------------------------------------------------
* file name: cgp_engine.h
* DESCRIPTION:
* Cartesian Genetic Programming (CGP) Engine for hardware-in-the-loop evolution.
* and
* Fault Injection (SPBI/MPBI and Stuck-At)
* --------------------------------------------------------------------------------
*/

#ifndef CGP_ENGINE_H
#define CGP_ENGINE_H

#include <stdint.h>

#define NUM_NODES    30
#define NUM_INPUTS   3
#define NUM_OUTPUTS  3
#define MAX_FITNESS  24
#define LAMBDA       4


// genotype [NUM_NODES * [F, in0, in1, in2, in3], out0, out1, out2]
// maps directly to VRC hardware registers over Avalon-MM
typedef struct {
	uint32_t routing[NUM_NODES];	// 20 LSBs used (4 inputs x 5 bits; I0 -bits 4-0)
	uint32_t F_table[NUM_NODES];	// 16 LSBs used (Truth table)
	uint32_t outputs;				// 18 LSBs used (3 outputs x 6 bits; Y0 -bits 5-0)
	int fitness;
} Individual;

// core engine declarations
Individual create_seed(uint32_t *rng_state);
int evaluate_individual(const Individual *ind);
void mutate_individual(const Individual *parent, Individual *child, uint32_t *rng_state);
void wait_for_fault();
void print_netlist(const Individual *ind);
void write_individual(const Individual *ind);

// fault injection declarations
void set_target_function(uint32_t pattern);
void inject_fault(uint8_t lut_index, uint16_t pbi_mask, uint8_t sa_en, uint8_t sa_val);
void heal_all();

#endif // CGP_ENGINE_H
