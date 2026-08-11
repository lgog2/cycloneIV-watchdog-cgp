/*--------------------------------------------------------------------------------
* file name: wrapper.vhd
* DESCRIPTION:
* Cartesian Genetic Programming (CGP) Engine for hardware-in-the-loop evolution.
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

// function declarations
Individual create_seed(uint32_t *rng_state);
int hw_evaluate_individual(const Individual *ind);
void mutate_individual(const Individual *parent, Individual *child, uint32_t *rng_state);
int hw_evaluate_individual(const Individual *ind);
void hw_wait_for_fault();
void print_netlist(const Individual *ind);

#endif // CGP_ENGINE_H
