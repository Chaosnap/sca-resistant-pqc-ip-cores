import random
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge

from tests.dilithium.dilithium import *
from tests.utils import *

TEST_CASES = 1000

async def compress_inputs(dut, inputs, mode):
    dut.s_axis_tuser.value = mode

    for i in inputs:
        dut.s_axis_tdata.value = i[0] + (i[1] << 24) + (i[2] << 48) + (i[3] << 72)
        dut.s_axis_tvalid.value = 1

        await RisingEdge(dut.clk)

        while dut.s_axis_tready.value != 1:
            await RisingEdge(dut.clk)

        dut.s_axis_tvalid.value = 0

        for _ in range(random.randint(1, 5)):
            await RisingEdge(dut.clk)

    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0

async def test_component(dut, mode, inputs, outputs, low_bits=False):
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

        if low_bits:
            # print(dut.m_axis_low_bits_tdata.value.buff.hex())
            # print(bytes.fromhex(f'{o[3]:06x}{o[2]:06x}{o[1]:06x}{o[0]:06x}').hex())
            assert dut.m_axis_low_bits_tdata.value.buff == bytes.fromhex(f'{o[3]:06x}{o[2]:06x}{o[1]:06x}{o[0]:06x}')
        else:
            # print(dut.m_axis_tdata.value.buff.hex())
            # print(bytes.fromhex(f'{o[3]:06x}{o[2]:06x}{o[1]:06x}{o[0]:06x}').hex())
            assert dut.m_axis_tdata.value.buff == bytes.fromhex(f'{o[3]:06x}{o[2]:06x}{o[1]:06x}{o[0]:06x}')

        dut.m_axis_tready.value = 0

        for _ in range(random.randint(0, 5)):
            await RisingEdge(dut.clk)

        dut.m_axis_tready.value = 1

        await RisingEdge(dut.clk)

async def test_compress_decompress(dut, mode, bound, is_compress):
    inputs = [[random.randint(0, 2 * bound) for _ in range(4)] for _ in range(TEST_CASES)]
    outputs = [[compress(x, bound) for x in i] for i in inputs]

    if not is_compress:
        inputs = outputs
        outputs = [[compress(x, bound) for x in i] for i in inputs]

        mode += 16

    await test_component(dut, mode, inputs, outputs)

async def test_decompose(dut, version):
    inputs = [[random.randint(0, Q) for _ in range(4)] for _ in range(TEST_CASES)]
    outputs = [[decompose(x, version)[1] for x in i] for i in inputs]

    await test_component(dut, 40 + version, inputs, outputs)

async def test_decompose_low_bits(dut, version):
    inputs = [[random.randint(0, Q) for _ in range(4)] for _ in range(TEST_CASES)]
    outputs = [[decompose(x, version)[0] % Q for x in i] for i in inputs]

    await test_component(dut, 56 + version, inputs, outputs, low_bits=True)

@cocotb.test()
async def test_compress(dut):
    for mode, bound in [(8, 0x80000), (9, 0x20000), (10, 0x1000), (14, 0x4), (15, 0x2)]:
        await test_compress_decompress(dut, mode, bound, True)

@cocotb.test()
async def test_decompress(dut):
    for mode, bound in [(8, 0x80000), (9, 0x20000), (10, 0x1000), (14, 0x4), (15, 0x2)]:
        await test_compress_decompress(dut, mode, bound, False)

@cocotb.test()
async def test_power2round(dut):
    inputs = [[random.randint(0, Q) for _ in range(4)] for _ in range(TEST_CASES)]
    outputs = [[power2round(x)[1] for x in i] for i in inputs]

    await test_component(dut, 43, inputs, outputs)

@cocotb.test()
async def test_power2round_low_bits(dut):
    inputs = [[random.randint(0, Q) for _ in range(4)] for _ in range(TEST_CASES)]
    outputs = [[power2round(x)[0] % Q for x in i] for i in inputs]

    await test_component(dut, 59, inputs, outputs, low_bits=True)

if __name__ == "__main__":
    run_tests('compress', 'tests.dilithium.compress_tb')
