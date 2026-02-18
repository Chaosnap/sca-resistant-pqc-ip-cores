import random
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge

from tests.dilithium.dilithium import *
from tests.utils import *

TEST_CASES = 100

async def make_hint_inputs(dut, inputs, mode):
    dut.mode.value = mode

    for w0s, w1s in inputs:
        for w0, w1 in zip(w0s, w1s):
            w0 = [x % Q for x in w0]

            for j in range(0, 256, 4):
                dut.coeffs.value = w0[j] + (w0[j + 1] << 24) + (w0[j + 2] << 48) + (w0[j + 3] << 72)
                dut.coeffs_high_bits.value = w1[j] + (w1[j + 1] << 6) + (w1[j + 2] << 12) + (w1[j + 3] << 18)
                dut.coeffs_vld.value = 1

                await RisingEdge(dut.clk)

                dut.coeffs_vld.value = 0

                for _ in range(random.randint(1, 5)):
                    await RisingEdge(dut.clk)

        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)

        while dut.outputing.value != 0:
            await RisingEdge(dut.clk)

    dut.mode.value = 0
    dut.coeffs.value = 0
    dut.coeffs_vld.value = 0

async def test_component(dut, mode, inputs, outputs):
    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    cocotb.start_soon(make_hint_inputs(dut, inputs, mode))

    dut.m_axis_tready.value = 1

    await RisingEdge(dut.clk)

    for o, valid in outputs:
        print(valid)
        if valid:
            for j in range(0, len(o), 8):
                while dut.m_axis_tvalid.value != 1:
                    await RisingEdge(dut.clk)

                # print(dut.m_axis_tdata.value.buff.hex())
                # print(bytes.fromhex(f'{o[j + 7]:02x}{o[j + 6]:02x}{o[j + 5]:02x}{o[j + 4]:02x}{o[j + 3]:02x}{o[j + 2]:02x}{o[j + 1]:02x}{o[j]:02x}').hex())
                assert dut.m_axis_tuser.value == 0
                assert dut.m_axis_tdata.value.buff == bytes.fromhex(f'{o[j + 7]:02x}{o[j + 6]:02x}{o[j + 5]:02x}{o[j + 4]:02x}{o[j + 3]:02x}{o[j + 2]:02x}{o[j + 1]:02x}{o[j]:02x}')

                dut.m_axis_tready.value = 0

                for _ in range(random.randint(0, 5)):
                    await RisingEdge(dut.clk)

                dut.m_axis_tready.value = 1

                await RisingEdge(dut.clk)
        else:
            while dut.m_axis_tvalid.value != 1:
                await RisingEdge(dut.clk)

            assert dut.m_axis_tuser.value == 1

            dut.m_axis_tready.value = 0

            for _ in range(random.randint(0, 5)):
                await RisingEdge(dut.clk)

            dut.m_axis_tready.value = 1

            await RisingEdge(dut.clk)

@cocotb.test()
async def test_make_hint_2(dut):
    w0 = [[[random.randint(int(-1.09 * (Q - 1)) // 88, int(1.09 * (Q - 1)) // 88) for _ in range(256)] for _ in range(4)] for _ in range(TEST_CASES)]
    w1 = [[[random.randint(0, 43) for _ in range(256)] for _ in range(4)] for _ in range(TEST_CASES)]
    inputs = list(zip(w0, w1))
    outputs = [make_hint(w0, w1, 2) for (w0, w1) in inputs]

    await test_component(dut, 0, inputs, outputs)

@cocotb.test()
async def test_make_hint_3(dut):
    w0 = [[[random.randint(int(-1.03 * (Q - 1)) // 32, int(1.03 * (Q - 1)) // 32) for _ in range(256)] for _ in range(6)] for _ in range(TEST_CASES)]
    w1 = [[[random.randint(0, 15) for _ in range(256)] for _ in range(6)] for _ in range(TEST_CASES)]
    inputs = list(zip(w0, w1))
    outputs = [make_hint(w0, w1, 3) for (w0, w1) in inputs]

    await test_component(dut, 1, inputs, outputs)

@cocotb.test()
async def test_make_hint_5(dut):
    w0 = [[[random.randint(int(-1.04 * (Q - 1)) // 32, int(1.04 * (Q - 1)) // 32) for _ in range(256)] for _ in range(8)] for _ in range(TEST_CASES)]
    w1 = [[[random.randint(0, 15) for _ in range(256)] for _ in range(8)] for _ in range(TEST_CASES)]
    inputs = list(zip(w0, w1))
    outputs = [make_hint(w0, w1, 5) for (w0, w1) in inputs]

    await test_component(dut, 2, inputs, outputs)

if __name__ == "__main__":
    run_tests('make_hint', 'tests.dilithium.make_hint_tb')
