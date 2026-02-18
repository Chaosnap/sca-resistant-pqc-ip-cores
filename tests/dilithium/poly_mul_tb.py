import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge

from tests.dilithium.dilithium import *
from tests.utils import *

TEST_CASES = 1

@cocotb.test()
async def test_poly_mul(dut):
    clk = Clock(dut.clk, 1, units='ns')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    dut.coeffs_in_vld.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    dut.top_mode.value = 1

    for _ in range(TEST_CASES):
        p = np.random.randint(0, Q, (256, ))
        r = np.random.randint(0, Q, (256, ))

        for i in range(0, 256, 4):
            dut.coeffs_in.value = int.from_bytes(bytes.fromhex(f'{p[i + 3]:06x}{p[i + 2]:06x}{p[i + 1]:06x}{p[i]:06x}'), byteorder='big')
            dut.coeffs_in_vld.value = 1

            await RisingEdge(dut.clk)

        for i in range(0, 256, 4):
            dut.coeffs_in.value = int.from_bytes(bytes.fromhex(f'{r[i + 3]:06x}{r[i + 2]:06x}{r[i + 1]:06x}{r[i]:06x}'), byteorder='big')
            dut.coeffs_in_vld.value = 1

            await RisingEdge(dut.clk)

        dut.coeffs_in_vld.value = 0

        z = poly_mul(p, r)

        while dut.coeffs_out_vld.value != 1:
            await RisingEdge(dut.clk)

        for i in range(0, 256, 4):
            await RisingEdge(dut.clk)

        for i in range(0, 256, 4):
            assert dut.coeffs_out.value.buff == bytes.fromhex(f'{z[i + 3]:06x}{z[i + 2]:06x}{z[i + 1]:06x}{z[i]:06x}')

            await RisingEdge(dut.clk)

if __name__ == "__main__":
    run_tests('poly_mul_top', 'tests.dilithium.poly_mul_tb')
