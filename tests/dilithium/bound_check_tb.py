import random
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge

from tests.dilithium.dilithium import *
from tests.utils import *

TEST_CASES = 100

async def bound_check_inputs(dut, inputs, mode, sec_level):
    dut.mode.value = mode

    k, l = k_l(sec_level)

    for i in inputs:
        for _ in range(l):
            for j in range(0, 256, 4):
                dut.coeffs.value = i[j] + (i[j + 1] << 24) + (i[j + 2] << 48) + (i[j + 3] << 72)
                dut.coeffs_vld.value = 1

                await RisingEdge(dut.clk)

                dut.coeffs_vld.value = 0

                if j != 252:
                    for _ in range(random.randint(1, 5)):
                        await RisingEdge(dut.clk)

    dut.mode.value = 0
    dut.coeffs.value = 0
    dut.coeffs_vld.value = 0

async def test_component(dut, mode, sec_level, inputs, outputs):
    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    cocotb.start_soon(bound_check_inputs(dut, inputs, mode, sec_level))

    await RisingEdge(dut.clk)

    for o in outputs:
        while dut.in_bound_vld.value != 1:
            await RisingEdge(dut.clk)

        print(dut.in_bound.value, o)
        assert dut.in_bound.value == (1 if o else 0)

        await RisingEdge(dut.clk)

@cocotb.test()
async def test_bound_check_z(dut):
    for sec_level, bound in [(2, 1 << 17), (3, 1 << 19), (5, 1 << 19)]:
        inputs = [[random.randint(-int(1.001 * bound), int(1.001 * bound)) for _ in range(256)] for _ in range(TEST_CASES)]
        outputs = [bound_check_z(i, sec_level) for i in inputs]

        inputs = [[x % Q for x in i] for i in inputs]

        mode = 0 if sec_level == 2 else 1 if sec_level == 3 else 2

        await test_component(dut, mode, sec_level, inputs, outputs)

if __name__ == "__main__":
    run_tests('bound_check', 'tests.dilithium.bound_check_tb')
