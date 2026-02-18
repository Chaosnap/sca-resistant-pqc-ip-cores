import random
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge

import copy

from tests.kyber.kyber import *
from tests.utils import *

TEST_CASES = 10000

async def butterfly_inputs(dut, inputs, offset = False):
    for a, b, z, mode in inputs:
        dut.A.value = a << 12 if offset else a
        dut.B.value = b << 12 if offset else b
        dut.zeta.value = z << 12 if offset else z
        dut.mode.value = mode
        dut.vld_in.value = 1

        await RisingEdge(dut.clk)

    dut.A.value = 0
    dut.B.value = 0
    dut.vld_in.value = 0

async def test_butterfly(dut, offset = False):
    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    a = random.choices(range(0, Q), k=TEST_CASES)
    b = random.choices(range(0, Q), k=TEST_CASES)
    z = random.choices(ZETAS, k=TEST_CASES)
    mode = random.choices([0, 1, 2, 3], k=TEST_CASES)

    inputs = list(zip(a, b, z, mode))

    cocotb.start_soon(butterfly_inputs(dut, copy.copy(inputs), offset=offset))

    await RisingEdge(dut.clk)

    while dut.vld_out.value != 1:
        await RisingEdge(dut.clk)

    for a, b, z, mode in inputs:
        assert (dut.C.value.integer >> 12 if offset else dut.C.value.integer, dut.D.value.integer >> 12 if offset else dut.D.value.integer) == butterfly(a, b, z, mode)

        await RisingEdge(dut.clk)

@cocotb.test()
async def test_butterfly0(dut):
    await test_butterfly(dut)

@cocotb.test()
async def test_butterfly1(dut):
    await test_butterfly(dut, offset=True)

if __name__ == "__main__":
    run_tests('butterfly', 'tests.kyber.butterfly_tb')
