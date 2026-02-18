import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge

import os
import time

from tests.utils import *

TEST_CASES = 1

@cocotb.test()
async def test_lfsr(dut):
    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    # dut.seed1.value = int.from_bytes(os.urandom(4), 'little') & 0x7fffffff
    # dut.seed2.value = int.from_bytes(os.urandom(4), 'little')
<<<<<<< Updated upstream
    dut.seed1.value = 0x3dae7fbb36f48731fe6d2145eb8c8952
    dut.seed2.value = 0xb14114bc67ea409178090844bf953fec
=======
    dut.seed1.value = 0x68a0f35b
    dut.seed2.value = 0x49e1a035
>>>>>>> Stashed changes
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

<<<<<<< Updated upstream
    start = time.time()
    for i in range(1034):
        await RisingEdge(dut.clk)
        # if dut.seed1_reg.value.integer == 1:
            # print(i, dut.seed1_reg.value.integer)
        print(dut.random.value.buff.hex(), end='')

    print()
    print(time.time() - start)

if __name__ == "__main__":
    run_tests('lfsr', 'tests.lfsr_tb', parameters={'SEED1_BITS': 127, 'SEED2_BITS': 128}, save_vcd=True)
=======
    f0 = open('100KB_LFSR_31.bin', 'wb')
    f1 = open('100KB_LFSR_32.bin', 'wb')
    f2 = open('100KB_COMBINED.bin', 'wb')
    for i in range(1_00_000):
        print(i)
        await RisingEdge(dut.clk)

        f0.write(dut.seed1_reg.value.buff)
        f1.write(dut.seed2_reg.value.buff)
        f2.write(dut.random.value.buff)

    f0.close()
    f1.close()
    f2.close()



def run_tests():
    r = get_runner('ghdl')
    r.build(vhdl_sources=['util_comps/lfsr.vhd'], hdl_toplevel='lfsr', always=True, build_args=['--std=08', '-frelaxed', '-fsynopsys'])
    r.test(hdl_toplevel='lfsr', test_module='lfsr_tb', test_args=['--std=08', '-frelaxed', '-fsynopsys'], plusargs=['--vcd=test.vcd'])

if __name__ == "__main__":
    run_tests()
>>>>>>> Stashed changes
