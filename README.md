### CGP Self-Healing Watchdog

A hardware-based, self-healing watchdog implemented on an Intel Cyclone IV FPGA (Terasic DE2-115). It monitors a target device's heartbeat and triggers a hard reset if the signal is lost.

The core logic runs on a **Virtual Reconfigurable Circuit (VRC)** — an unclocked, combinational matrix of 30 custom `LUT4Cell` nodes constituting a Directed Acyclic Graph (DAG). Cartesian Genetic Programming (CGP) algorithm dynamically reconfigures this matrix to autonomously bypass physical hardware faults.

### Key Architecture
* **Hardware-In-The-Loop (HIL):** A direct VHDL continuation of the [previous iCE40 VERILOG project](https://github.com/lgog2/icesugar-watchdog-cgp), moving from software-simulated faults to on-chip fault injection.
* **16.6M Cycle Evolution Window:** The FPGA runs at 50 MHz, but the external RC analog timebase operates at 3 Hz. This decoupling provides a 16.6-million-cycle window for background evaluation and reconfiguration without blocking the watchdog operations.
* **Massive Search Space:** Besides rerouting flexibility, each of the 30 `LUT4Cell` nodes can be dynamically reprogrammed with any of the 65,536 ($2^{16}$) 4-input Boolean functions. That allows discovery of unconventional logic structures and theoretically provides a mechanism for autonomous healing of not only VRC faults, but also faults occurring in the underlying actual FPGA structure.
* **Hybrid Hardware-Software Co-Design:** A Nios II softcore processor executes the evolutionary algorithm to reconfigure the hardware VRC matrix. This software engine is safely decoupled from the real-time FPGA logic via avs_waitrequest signal acting as strict read-after-write barrier.

### Roadmap & Status

**Current**
* Physical hardware interface operational (50 MHz system clock bridged to 3 Hz analog domain via wrapper FSM).
* Initial static validation completed using a hardcoded DAG logic (3 LUTs out of 30) to prove external Watchdog functionality.
* Memory-mapped control registers for dynamic reconfiguration implemented.
* Nios II softcore integrated with custom BSP, utilizing cascaded hardware multipliers (`mulxuu`) for Fast Range math optimization.
* Full (1+4) Evolution Strategy implemented in C on the Nios II processor, with time measured via a dedicated Interval Timer IP.
* Hardware fault injection network: shadow registers (XOR/AND/OR overlay) to emulate faults (Stuck-At, SEU, MBU) configured from Nios II processor.
* Fitness truth table for hardware validator is Nios-reconfigurable and protected by zero-cycle hardware TMR.
* Self-Healing Validated: System autonomously recovers from fault injections via evolutionary reconfiguration.
* Active phenotype extraction implemented using a Reverse Topological Traversal algorithm to visualize the resulting DAG structure.


**TODO**

* Full hardware implementation of the evolutionary algorithm to eliminate software overhead and
decouple the evolutionary engine from NIOS II fault injection.
* Stress testing of self-healing capabilities and fault recovery functionality of the system.
* Spatial efficiency analysis: comparing CGP fault capacity against static N-modular redundancy. Static redundancy treats any fault as a fatal node failure. The CGP engine does not discard faulty nodes but exploits their remaining partial functionality. This allows the system to theoretically survive a massive, topology-dependent number of faults, provided the residual matrix retains enough logical plasticity to map the target function.

**Future Exploration**
* Dual Fault Tolerance (combining CGP with TMR).


### Physical Setup
* **Dual RC Circuit:** Two analog 'hourglasses' measure the heartbeat timeout and reset duration (verified via oscilloscope).
* **Power Isolation:** An AQV252G solid-state relay safely cuts the 5V power supply to the target device using 3.3V FPGA logic.
* **Live Demonstration - video:** An external yellow LED simulates the target. A manually triggered wire simulates its heartbeat. Two onboard red LEDs indicate the 3 Hz operational cycle and heartbeat registration, while 4 other green LEDs indicate I/O states.

> *Note: Detailed schematics of the external analog circuit are available in the [iCE40 repository](https://github.com/lgog2/icesugar-watchdog-cgp).*


https://github.com/user-attachments/assets/d484a216-dc1b-479f-acab-ee73b231c612




