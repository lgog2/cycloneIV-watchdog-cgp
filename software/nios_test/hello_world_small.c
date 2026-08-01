#include "sys/alt_irq.h"
#include "sys/alt_stdio.h"
#include "system.h"
#include "io.h"
#include <stdint.h>
//#include "alt_types.h" for alt_u32 instead of uint32_t
#include <stdio.h>

// ==============================================================================
// TEST of NIOS - Watchdog communication and IRQ:
// Expected result: continuous loop reporting State Panic and non-ideal fitness
// if system starts with unconfigured LUTs and DAG.
// If starting from preconfigured DAG with perfect seed and max fitness
// - no interrupt will be triggered.
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
	// capture the hardware status at the moment of the interrupt
	status = IORD_32DIRECT(CGP_WATCHDOG_BASE, 62 * 4);

	irq_triggered = 1;
}

int main()
{
	alt_putstr("Test start\n");

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
			// restart_cmd to Watchdog FSM
			IOWR_32DIRECT(CGP_WATCHDOG_BASE, 61 * 4, 0x01);

			// reading from Avalon to ensure FSM is no longer in stRepair or stPanic before re-enabling irqs
			uint32_t polling_status;
			do {
				polling_status = IORD_32DIRECT(CGP_WATCHDOG_BASE, 62 * 4);
			} while (((polling_status >> 1) & 0x01) == 1 || (polling_status & 0x01) == 1);

			//reading from Avalon bus to ensure restart_cmd was already passed to FSM before re-enabling irqs
			//volatile uint32_t dummy = IORD_32DIRECT(CGP_WATCHDOG_BASE, 62 * 4);
			//(void)dummy; // preventing comipiler from optimizing it out

			alt_ic_irq_enable(CGP_WATCHDOG_IRQ_INTERRUPT_CONTROLLER_ID, CGP_WATCHDOG_IRQ);

			if ( counter == 0)
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
