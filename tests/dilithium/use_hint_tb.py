import random
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge

from tests.dilithium.dilithium import *
from tests.utils import *

TEST_CASES = 100

async def use_hint_inputs(dut, inputs, mode):
    dut.mode.value = mode

    for (hints, valid), _, w1s in inputs:
        for i in range(0, len(hints), 8):
            # if not valid:
            #     print(hints[i:i + 8])
            dut.s_axis_tdata.value = int.from_bytes(bytes(hints[i:i + 8]), 'little')
            dut.s_axis_tvalid.value = 1

            await RisingEdge(dut.clk)

            while dut.s_axis_tready.value != 1:
                await RisingEdge(dut.clk)

            dut.s_axis_tvalid.value = 0

            for _ in range(random.randint(0, 5)):
                await RisingEdge(dut.clk)

            if (mode == 0 and i == 80) or (mode == 1 and i == 56) or (mode == 2 and i == 80):
                break

        if not valid:
            dut.s_axis_tdata.value = 0
            dut.s_axis_tvalid.value = 1

            while dut.hints_invalid.value != 1:
                await RisingEdge(dut.clk)

            continue

        for w1 in w1s:
            w1 = [x % Q for x in w1]
            for j in range(0, 256, 4):
                dut.s_axis_tdata.value = w1[j] + (w1[j + 1] << 16) + (w1[j + 2] << 32) + (w1[j + 3] << 48)
                dut.s_axis_tvalid.value = 1

                await RisingEdge(dut.clk)

                while dut.s_axis_tready.value != 1:
                    await RisingEdge(dut.clk)

                dut.s_axis_tvalid.value = 0

                for _ in range(random.randint(0, 5)):
                    await RisingEdge(dut.clk)

        await RisingEdge(dut.clk)

        while dut.outputing.value != 0:
            await RisingEdge(dut.clk)

    dut.mode.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0

async def test_component(dut, mode, inputs, outputs):
    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    await RisingEdge(dut.clk)

    cocotb.start_soon(use_hint_inputs(dut, inputs, mode))

    dut.m_axis_tready.value = 1

    await RisingEdge(dut.clk)

    for w1s, valid in outputs:
        print(valid)
        if valid:
            for w1 in w1s:
                w1 = [x % Q for x in w1]
                for j in range(0, 256, 4):
                    while dut.m_axis_tvalid.value != 1:
                        await RisingEdge(dut.clk)

                    # print(j, dut.m_axis_tdata.value.buff.hex())
                    # print(hex(w1[j] + (w1[j + 1] << 6) + (w1[j + 2] << 12) + (w1[j + 3] << 18)))
                    # assert dut.m_axis_tuser.value == 0
                    assert dut.m_axis_tdata.value.integer == w1[j] + (w1[j + 1] << 6) + (w1[j + 2] << 12) + (w1[j + 3] << 18)

                    dut.m_axis_tready.value = 0

                    for _ in range(random.randint(0, 5)):
                        await RisingEdge(dut.clk)

                    dut.m_axis_tready.value = 1

                    await RisingEdge(dut.clk)
        else:
            i = 0
            while dut.hints_invalid.value != 1:
                i += 1
                if i == 1000:
                    assert False

                await RisingEdge(dut.clk)

            await RisingEdge(dut.clk)

@cocotb.test()
async def test_use_hint_2(dut):
    w0 = [[[random.randint(int(-1.09 * (Q - 1)) // 88, int(1.09 * (Q - 1)) // 88) for _ in range(256)] for _ in range(4)] for _ in range(TEST_CASES)]
    w1 = [[[random.randint(0, 43) for _ in range(256)] for _ in range(4)] for _ in range(TEST_CASES)]
    hints = [make_hint(w0, w1, 2) for (w0, w1) in zip(w0, w1)]
    inputs = list(zip(hints, w0, w1))
    outputs = [(use_hint(hint, valid, w0, w1, 2), valid) for ((hint, valid), w0, w1) in inputs]

    await test_component(dut, 0, inputs, outputs)

@cocotb.test()
async def test_use_hint_3(dut):
    w0 = [[[random.randint(int(-1.03 * (Q - 1)) // 32, int(1.03 * (Q - 1)) // 32) for _ in range(256)] for _ in range(6)] for _ in range(TEST_CASES)]
    w1 = [[[random.randint(0, 15) for _ in range(256)] for _ in range(6)] for _ in range(TEST_CASES)]
    hints = [make_hint(w0, w1, 3) for (w0, w1) in zip(w0, w1)]
    inputs = list(zip(hints, w0, w1))
    outputs = [(use_hint(hint, valid, w0, w1, 3), valid) for ((hint, valid), w0, w1) in inputs]

    await test_component(dut, 1, inputs, outputs)

@cocotb.test()
async def test_use_hint_5(dut):
    w0 = [[[random.randint(int(-1.04 * (Q - 1)) // 32, int(1.04 * (Q - 1)) // 32) for _ in range(256)] for _ in range(8)] for _ in range(TEST_CASES)]
    w1 = [[[random.randint(0, 15) for _ in range(256)] for _ in range(8)] for _ in range(TEST_CASES)]
    hints = [make_hint(w0, w1, 5) for (w0, w1) in zip(w0, w1)]
    inputs = list(zip(hints, w0, w1))
    outputs = [(use_hint(hint, valid, w0, w1, 5), valid) for ((hint, valid), w0, w1) in inputs]

    await test_component(dut, 2, inputs, outputs)

if __name__ == "__main__":
    run_tests('use_hint', 'tests.dilithium.use_hint_tb')
