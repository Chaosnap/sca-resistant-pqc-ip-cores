import random
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge

import copy

from tests.kyber.kyber import *
from tests.utils import *

TEST_CASES = 10000

async def barrett_reduce_inputs(dut, inputs, offset = False):
    for i in inputs:
        dut.X.value = i << 24 if offset else i
        dut.vld_in.value = 1

        await RisingEdge(dut.clk)

    dut.X.value = 0
    dut.vld_in.value = 0

async def test_barrett_reduce(dut, offset = False):
    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    dut.mode.value = 0

    inputs = random.sample(range(0, Q * Q), TEST_CASES)

    cocotb.start_soon(barrett_reduce_inputs(dut, copy.copy(inputs), offset))

    await RisingEdge(dut.clk)

    while dut.vld_out.value != 1:
        await RisingEdge(dut.clk)

    for i in inputs:
        assert dut.Z.value.integer == (barrett_reduce(i) << 12 if offset else barrett_reduce(i))

        await RisingEdge(dut.clk)

@cocotb.test()
async def test_barrett_reduce0(dut):
    await test_barrett_reduce(dut)

@cocotb.test()
async def test_barrett_reduce1(dut):
    await test_barrett_reduce(dut, offset=True)

if __name__ == "__main__":
    run_tests('barrett_reduce', 'tests.kyber.barrett_reduce_tb')
