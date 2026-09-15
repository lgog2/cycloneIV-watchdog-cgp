### CGP Self-Healing Watchdog

A hardware-based, self-healing watchdog implemented on an Intel Cyclone IV FPGA (Terasic DE2-115). It monitors a target device's heartbeat and triggers a hard reset if the signal is lost.

The core logic runs on a [Virtual Reconfigurable Circuit (VRC)](core.vhd) — an unclocked, combinational matrix of 30 custom [LUT4Cell](LUT4Cell.vhd) nodes constituting a Directed Acyclic Graph (DAG). A Cartesian Genetic Programming (CGP) algorithm dynamically reconfigures this matrix to autonomously bypass physical hardware faults.
A synchronous [Wrapper FSM](wrapper.vhd) encapsulates the VRC, bridging the 50 MHz system clock with the 3 Hz sampling and control rate of the external analog RC circuit. This allows the system to execute real-time watchdog operations (3 Hz) while concurrently driving background evaluations and the hardware evolutionary loop (50 MHz).

### Key Architecture
* **Hardware-In-The-Loop (HIL):** A direct VHDL continuation of the [previous iCE40 VERILOG project](https://github.com/lgog2/icesugar-watchdog-cgp), moving from software-simulated faults to on-chip fault injection.
* **Hardware-Software Co-Design:** The VRC and hardware FSM operate autonomously. The system integrates a Nios II softcore processor that serves as a control tool, a fault-injection host, a telemetry logger and a prototyping environment for evolutionary algorithms.
* **Dual-Mode Evolution Engine:** The system features two independent recovery mechanisms:
  * **Hardware (1+1)-ES:** An autonomous, purely hardware-driven evolution state machine executing Background Repair. Powered by a [64-bit PRNG](xorshift64.vhd) and an asynchronous, combinatorial [Mutation Engine](mutation_engine.vhd) utilizing DSP multipliers (Lemire's Fast Scaling) to evaluate mutants in ~67 clock cycles.
  * **Software (1+4)-ES:** A current baseline C implementation running on a Nios II softcore processor, utilized for comparative benchmarking.
* **16.6M Cycle Evolution Window:** The FPGA runs at 50 MHz, while the external RC circuit is sampled and controlled at 3 Hz. This decoupling provides a 16.6-million-cycle window for background evaluation and reconfiguration without blocking the watchdog operations.
* **Massive Search Space:** Besides rerouting flexibility, each of the 30 `LUT4Cell` nodes can be dynamically reprogrammed with any of the 65,536 ($2^{16}$) 4-input Boolean functions. This allows the discovery of unconventional logic structures and theoretically provides a mechanism for autonomous healing of not only VRC faults, but also faults occurring in the underlying actual FPGA structure.

### Roadmap & Status

**Current**
* Physical hardware interface operational (50 MHz system clock bridged to 3 Hz analog domain via wrapper FSM).
* Initial static validation completed using a hardcoded DAG logic (3 LUTs out of 30) to prove external Watchdog functionality.
* Nios II softcore integrated with custom BSP, utilizing cascaded hardware multipliers (`mulxuu`) for Fast Range math optimization.
* Memory-mapped Avalon-MM interface implemented. Includes shadow registers (routing, logic, outputs) for dynamic reconfiguration without data tearing, a dedicated control register (`control_reg`) for FSM execution modes/PRNG seeding, and status register (`status_reg`) exposing hardware FSM flags (panic, repair) and current fitness to the Nios II processor.
* Fully operational hardware (1+1)-ES background evolution capable of autonomous failure recovery without CPU intervention.
* Full (1+4) Evolution Strategy implemented in C on the Nios II processor, with time measured via a dedicated Interval Timer IP.
* Hardware fault injection network configured from Nios II processor: shadow registers (XOR/AND/OR overlays) to emulate Hard Faults (Permanent Bit Inversion, Stuck-At-0, Stuck-At-1) directly in the logic matrix.
* Fitness truth table for the hardware validator is Nios-reconfigurable and protected by zero-cycle hardware Triple Modular Redundancy (TMR).
* Self-Healing Validated: System autonomously recovers from fault injections via evolutionary reconfiguration.
* Comparative Testing: [Benchmark](software/hardware_evolution_test/main.c) of Nios II (1+4)-ES against Hardware (1+1)-ES under fault injections, confirming orders-of-magnitude speed advantages for silicon-based recovery.
* Active software-based phenotype extraction implemented using a Reverse Topological Traversal algorithm to visualize the resulting DAG structure.


**TODO**

* Efficiency analysis: comparing CGP fault capacity against static N-modular redundancy. Static redundancy treats any fault as a fatal node failure. The CGP engine does not discard faulty nodes but exploits their remaining partial functionality. This allows the system to theoretically survive a massive, topology-dependent number of faults, provided the residual matrix retains enough logical plasticity to map the target function.

**Future Exploration**
* Dual Fault Tolerance (combining CGP with TMR).

### Resource Utilization (Cyclone IV EP4CE115F29C7)
* **Total logic elements:** 11,122 / 114,480 (10%)
* **Total registers:** 5,460
* **Total memory bits:** 570,624 / 3,981,312 (14%)
* **Embedded Multiplier 9-bit elements:** 16 / 532 (3%)

### Physical Setup
* **Dual RC Circuit:** Two analog 'hourglasses' measure the heartbeat timeout and reset duration (verified via oscilloscope).
* **Power Isolation:** An AQV252G solid-state relay safely cuts the 5V power supply to the target device using 3.3V FPGA logic.
* **Live Demonstration - video:** Demonstrates the normal operation of the watchdog (baseline functionality without fault injection). An external yellow LED simulates the target. A manually triggered wire simulates its heartbeat. Two onboard red LEDs indicate the 3 Hz operational cycle and heartbeat registration, while 4 other green LEDs indicate I/O states.


> *Note: Detailed schematics of the external analog circuit are available in the [iCE40 repository](https://github.com/lgog2/icesugar-watchdog-cgp).*

https://github.com/user-attachments/assets/a17d88b5-d474-4fec-8ac6-e5ef11028020
