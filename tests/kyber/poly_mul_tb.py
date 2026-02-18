import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge

from tests.kyber.kyber import *
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

    dut.top_mode.value = 0

    for _ in range(TEST_CASES):
        p = np.random.randint(0, Q, (256, ))
        r = np.random.randint(0, Q, (256, ))

        for i in range(0, 256, 8):
            dut.coeffs_in.value = int.from_bytes(bytes.fromhex(f'{p[i + 7]:03x}{p[i + 6]:03x}{p[i + 5]:03x}{p[i + 4]:03x}{p[i + 3]:03x}{p[i + 2]:03x}{p[i + 1]:03x}{p[i]:03x}'), byteorder='big')
            dut.coeffs_in_vld.value = 1

            await RisingEdge(dut.clk)

        for i in range(0, 256, 8):
            dut.coeffs_in.value = int.from_bytes(bytes.fromhex(f'{r[i + 7]:03x}{r[i + 6]:03x}{r[i + 5]:03x}{r[i + 4]:03x}{r[i + 3]:03x}{r[i + 2]:03x}{r[i + 1]:03x}{r[i]:03x}'), byteorder='big')
            dut.coeffs_in_vld.value = 1

            await RisingEdge(dut.clk)

        dut.coeffs_in_vld.value = 0

        z = poly_mul(p, r)

        while dut.coeffs_out_vld.value != 1:
            await RisingEdge(dut.clk)

        for i in range(0, 256, 8):
            await RisingEdge(dut.clk)

        for i in range(0, 256, 8):
            assert dut.coeffs_out.value.buff == bytes.fromhex(f'{z[i + 7]:03x}{z[i + 6]:03x}{z[i + 5]:03x}{z[i + 4]:03x}{z[i + 3]:03x}{z[i + 2]:03x}{z[i + 1]:03x}{z[i]:03x}')

            await RisingEdge(dut.clk)

if __name__ == "__main__":
    run_tests('poly_mul_top', 'tests.kyber.poly_mul_tb')
