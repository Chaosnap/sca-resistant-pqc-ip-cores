import random
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge

from tests.dilithium.dilithium import *
from tests.utils import *

TEST_CASES = 10000

async def butterfly_inputs(dut, inputs):
    for a, b, z, mode in inputs:
        dut.A.value = a
        dut.B.value = b
        dut.zeta.value = z
        dut.mode.value = mode + 4
        dut.vld_in.value = 1

        await RisingEdge(dut.clk)

    dut.A.value = 0
    dut.B.value = 0
    dut.vld_in.value = 0

@cocotb.test()
async def test_butterfly(dut):
    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    a = random.choices(range(0, Q), k=TEST_CASES)
    b = random.choices(range(0, Q), k=TEST_CASES)
    z = random.choices(ZETAS, k=TEST_CASES)
    mode = random.choices([0, 1, 2], k=TEST_CASES)

    inputs = list(zip(a, b, z, mode))

    cocotb.start_soon(butterfly_inputs(dut, inputs))

    await RisingEdge(dut.clk)

    while dut.vld_out.value != 1:
        await RisingEdge(dut.clk)

    for a, b, z, mode in inputs:
        assert (dut.C.value.integer, dut.D.value.integer) == butterfly(a, b, z, mode)

        await RisingEdge(dut.clk)

if __name__ == "__main__":
    run_tests('butterfly', 'tests.dilithium.butterfly_tb')
