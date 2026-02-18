import random
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge

from tests.kyber.kyber import *
from tests.utils import *

TEST_CASES = 100

async def compress_inputs(dut, inputs, mode):
    dut.s_axis_tuser.value = mode

    for i in inputs:
        dut.s_axis_tdata.value = i[0] + (i[1] << 12) + (i[2] << 24) + (i[3] << 36) + (i[4] << 48) + (i[5] << 60) + (i[6] << 72) + (i[7] << 84)
        dut.s_axis_tvalid.value = 1

        await RisingEdge(dut.clk)

        while dut.s_axis_tready.value != 1:
            await RisingEdge(dut.clk)

        dut.s_axis_tvalid.value = 0

        for _ in range(random.randint(1, 5)):
            await RisingEdge(dut.clk)

    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0

async def test_component(dut, mode, bits, is_compress):
    inputs = [[random.randint(0, Q) for _ in range(8)] for _ in range(TEST_CASES)]
    outputs = [[(0x681 if compress(x, bits) == 1 else 0x0) if is_compress and bits == 1 else compress(x, bits) for x in i] for i in inputs]

    if not is_compress:
        inputs = outputs
        outputs = [[decompress(x, bits) for x in i] for i in inputs]

        mode += 16

    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    cocotb.start_soon(compress_inputs(dut, inputs, mode))

    dut.m_axis_tready.value = 1

    await RisingEdge(dut.clk)

    for o in outputs:
        while dut.m_axis_tvalid.value != 1:
            await RisingEdge(dut.clk)

        assert dut.m_axis_tdata.value.buff == bytes.fromhex(f'{o[7]:03x}{o[6]:03x}{o[5]:03x}{o[4]:03x}{o[3]:03x}{o[2]:03x}{o[1]:03x}{o[0]:03x}')

        dut.m_axis_tready.value = 0

        for _ in range(random.randint(0, 5)):
            await RisingEdge(dut.clk)

        dut.m_axis_tready.value = 1

        await RisingEdge(dut.clk)

@cocotb.test()
async def test_compress(dut):
    for i, mode in enumerate([12, 11, 10, 5, 4, 1]):
        await test_component(dut, i, mode, True)

@cocotb.test()
async def test_decompress(dut):
    for i, mode in enumerate([12, 11, 10, 5, 4, 1]):
        await test_component(dut, i, mode, False)

if __name__ == "__main__":
    run_tests('compress', 'tests.kyber.compress_tb')
