#include <stdio.h>
#include "sys/alt_irq.h"
#include "sys/alt_stdio.h"
#include "system.h"
#include "io.h"
#include <stdint.h>
#include <stdint.h>
//#include "alt_types.h" for alt_u32 instead of uint32_t

// ==============================================================================
// TEST of dynamic DAG configuration from NIOS
// Expected result:
// exactly one interrupt is triggered due to FSM state panic before
// loading the perfect seed from NIOS
// after that no more interrupts occur
// ==============================================================================


volatile uint32_t irq_triggered = 0;
volatile uint32_t status = 0;

void print_binary32(uint32_t val)
{
	int i;
	for (i = 31; i >= 0; i--)
	{
		if ((val >> i) & 1)
		{
			putchar('1');
		}
		else
		{
			putchar('0');
		}

		// space every 4 bits
		if (i % 4 == 0 && i > 0)
		{
			putchar(' ');
		}
	}
}

static void cgpw_isr(void *context)
{
	// disable interrupts to prevent nested IRQs and allow JTAG UART (printf) to operate
	alt_ic_irq_disable(CGP_WATCHDOG_IRQ_INTERRUPT_CONTROLLER_ID, CGP_WATCHDOG_IRQ);
	status = IORD_32DIRECT(CGP_WATCHDOG_BASE, 62 * 4);
	irq_triggered = 1;
}

// function which loads configuration of DAG - filling 61 registers
void cgp_load_initial_seed(void)
{
	alt_putstr("Configuring DAG with perfect seed.\n");

	// routing for LUTs 0 to 29
	for (int i = 0; i < 30; i++)
	{
		uint32_t routing_word = 0;

		if (i == 0) {
			// conf_routing(0) <= "00000" & "00010" & "00001" & "00000"; (I3=0, I2=2, I1=1, I0=0)
			routing_word = 0x00820;
		} else if (i == 1) {
			//conf_routing(1) <= "00000" & "00000" & "00000" & "00000";
			routing_word = 0x000000;
		} else if (i == 2) {
			//conf_routing(2) <= "00000" & "00000" & "00001" & "00000";
			routing_word = 0x00020;
		} else {
			routing_word = 0x000000; // x0 to rest
		}

		//uint32_t routing_word = (i == 0) ? 0x00820 : (i == 2) ? 0x00020 : 0x00000;

		// write to conf_routing registers  (addresses 0 to 29)
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, i * 4, routing_word);
	}

	// function F for LUTs 0 to 29(conf_F)
	for (int i = 0; i < 30; i++)
	{
		uint32_t func_word = 0;

		if (i == 0) {
			func_word = 0xDCDC; // y0 = (I2 & ~I0) | I1
		} else if (i == 1) {
			func_word = 0x5555; // y1 = ~I0
		} else if (i == 2) {
			func_word = 0x2222; // y2 = I0 & ~I1
		} else {
			func_word = 0x0000; // all zeroes for rest
		}

		//uint32_t func_word = (i == 0) ? 0xDCDC : (i == 1) ? 0x5555 : (i == 2) ? 0x2222 : 0x0000;

		// write to conf_F registers  (addresses 30 to 59)
		IOWR_32DIRECT(CGP_WATCHDOG_BASE, (30 + i) * 4, func_word);
	}

	// address 60: exits configuration (conf_out)
	// y0 to LUT0, y1 to LUT1, y2 to LUT2: conf_out(0) = 3, conf_out(1) = 4, conf_out(2) = 5
	// packed to 32bit word: (5 << 12) | (4 << 6) | 3 = 0101 0001 0000 0011 = 0x5103
	uint32_t outputs_word = 0x5103;
	IOWR_32DIRECT(CGP_WATCHDOG_BASE, 60 * 4, outputs_word);

	alt_putstr("Seed loaded.\n");
}

int main()
{
	alt_putstr("Test start\n");

	// seeding the DAG
	cgp_load_initial_seed();

	alt_ic_isr_register(CGP_WATCHDOG_IRQ_INTERRUPT_CONTROLLER_ID,
						CGP_WATCHDOG_IRQ,
						cgpw_isr,
						NULL,
						0);

	uint32_t counter = 0;

	while (1)
	{
		if (irq_triggered)
		{
			uint32_t local_status = status;
			irq_triggered = 0;

			// restart_cmd to Watchdog FSM (address 61)
			IOWR_32DIRECT(CGP_WATCHDOG_BASE, 61 * 4, 0x01);

			// reading from Avalon to ensure FSM is no longer in stRepair or stPanic before re-enabling irqs
			uint32_t polling_status;
			do {
				polling_status = IORD_32DIRECT(CGP_WATCHDOG_BASE, 62 * 4);
			} while (((polling_status >> 1) & 0x01) == 1 || (polling_status & 0x01) == 1);

			//volatile uint32_t dummy = IORD_32DIRECT(CGP_WATCHDOG_BASE, 62 * 4);
			//(void)dummy;// preventing compiler from optimizing it out

			alt_ic_irq_enable(CGP_WATCHDOG_IRQ_INTERRUPT_CONTROLLER_ID, CGP_WATCHDOG_IRQ);

			if (counter == 0)
			{
				uint32_t panic  = local_status & 0x01;
				uint32_t repair = (local_status >> 1) & 0x01;
				uint32_t fitness = (local_status >> 8) & 0x1F;

				printf("Status register: ");
				print_binary32(local_status);
				printf("\ndecoded parts: Panic: %lx | Repair: %lx | Fitness: %d\n\n",
							panic, repair, (int)fitness);

			}

			++counter;

			if (counter >= 1000000)
			{
				counter = 0;
			}
		}
	}
	return 0;
}



