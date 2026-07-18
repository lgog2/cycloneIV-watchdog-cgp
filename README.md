### CGP Self-Healing Watchdog

A hardware-based, self-healing watchdog implemented on an Intel Cyclone IV FPGA (Terasic DE2-115). It monitors a target device's heartbeat and triggers a hard reset if the signal is lost.

The core logic runs on a **Virtual Reconfigurable Circuit (VRC)** — an unclocked, combinational matrix of 30 custom `LUT4Cell` nodes. Cartesian Genetic Programming (CGP) algorithm dynamically reconfigures this matrix to autonomously bypass physical hardware faults.

### Key Architecture
* **Hardware-In-The-Loop (HIL):** A direct VHDL continuation of the [previous iCE40 VERILOG project](https://github.com/lgog2/icesugar-watchdog-cgp), moving from software-simulated faults to on-chip fault injection.
* **16.6M Cycle Evolution Window:** The FPGA runs at 50 MHz, but the external RC analog timebase operates at 3 Hz. This decoupling provides 16.6-million-cycle window for background evaluation and reconfiguration without blocking the watchdog operations.
* **Massive Search Space:** Besides rerouting flexibility, each of the 30 `LUT4Cell` nodes can be dynamically reprogrammed with any of the 65,536 ($2^{16}$) 4-input Boolean functions. That allows discovery of unconventional logic structures and theoretically provides a mechanism for autonomous healing of not only VRC faults, but also actual faults occurring in the underlying FPGA structure.


### Roadmap & Status

**Phase 1: Static Prototype (v1.0 - Current)**
The physical hardware interface is fully operational. A wrapper FSM bridges the fast 50 MHz system clock with the slow 3 Hz analog domain. Currently, the VRC uses a static, hardcoded logic (3 LUTs out of 30) simply to prove the external Watchdog functionality.

**TODO**
* Upgrading the static DAG with memory-mapped control registers for dynamic reconfiguration and hardware fault injection.
* Integrating the Nios II softcore to run the CGP algorithm directly on-chip.

**Final goal: Autonomous Healing & TMR**
* Replacing the hardcoded truth-table evaluator with Triple Modular Redundancy (TMR). Three identical VRCs will run in parallel. A faulty graph will be isolated using majority voting and healed in the background via CGP.

### Physical Setup
* **Dual RC Circuit:** Two analog 'hourglasses' measure the heartbeat timeout and reset duration (verified via oscilloscope).
* **Power Isolation:** An AQV252G solid-state relay safely cuts the 5V power supply to the target device using 3.3V FPGA logic.
* **Live Demonstration - video:** An external yellow LED simulates the target. A manually triggered wire simulates its heartbet. Two onboard red LEDs indicate the 3 Hz operational cycle and hearbeat registration, while 4 other green LEDS indicate I/O states.

> *Note: Detailed schematics of the external analog circuit are available in the [iCE40 repository](https://github.com/lgog2/icesugar-watchdog-cgp).*


https://github.com/user-attachments/assets/d484a216-dc1b-479f-acab-ee73b231c612




