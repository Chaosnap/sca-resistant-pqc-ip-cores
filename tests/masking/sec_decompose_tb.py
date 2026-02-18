import random

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, RisingEdge

from tests.utils import *
from tests.dilithium.dilithium import *

TEST_CASES = 1000

async def send_inputs(dut, inputs_gen, mode=None):
    if mode != None:
        dut.s_axis_tuser.value = mode

    async for x in inputs_gen():
        dut.s_axis_tdata.value = x
        dut.s_axis_tvalid.value = 1

        await wait_for_signal(dut.clk, dut.s_axis_tready)

        dut.s_axis_tvalid.value = 0

        await wait_for_random_delay(dut.clk)

    dut.s_axis_tdata.value = [0, 0]
    if mode != None:
        dut.s_axis_tuser.value = 0
    dut.s_axis_tvalid.value = 0

async def test_decompose(dut, inputs_gen, mode, check_fn):
    await initialize_component(dut)

    cocotb.start_soon(send_randomness(dut.sec_conversion_random, dut.clk, 776, Q))
    cocotb.start_soon(send_randomness(dut.other_random, dut.clk, 24, q=44 if mode == 0 else 16, from_zero=True))
    cocotb.start_soon(send_inputs(dut, inputs_gen, mode))

    dut.m_axis_tready.value = 0

    dut.m_axis_tready.value = 1
    for _ in range(TEST_CASES):
        await wait_for_signal(dut.clk, dut.m_axis_tvalid)

        assert await check_fn(dut.m_axis_tdata.value, dut.m_axis_low_bits_tdata.value)

        dut.m_axis_tready.value = 0

        await wait_for_random_delay(dut.clk)

        dut.m_axis_tready.value = 1

@cocotb.test()
async def test_sec_decompose_dilithium_16(dut):
    expected_outputs = Queue()

    async def inputs_gen():
        for i in range(TEST_CASES):
            x = [random.getrandbits(24) % Q for _ in range(4)]
            r = [random.getrandbits(24) % Q for _ in range(4)]

            await expected_outputs.put((serialize_coeffs([decompose(u, 1)[0] % Q for u in x]), serialize_coeffs([decompose(u, 1)[1] for u in x])))

            yield [serialize_coeffs([(x[i] - r[i]) % Q for i in range(4)]), serialize_coeffs(r)]

    async def check_fn(high_bits, low_bits):
        expected = await expected_outputs.get()

        # low bits
        out = 0
        for i in range(4):
            out += (((((low_bits[0] >> (i * 24)) & 0xffffff) + (low_bits[1] >> (i * 24)) & 0xffffff)) % Q) << (i * 24)

        # print(hex(out), hex(expected[0]))
        if out != expected[0]:
            return False

        # high bits
        out = 0
        for i in range(4):
            out += ((high_bits >> (i * 6)) & 0x3f) << (i * 24)

        # print(hex(out), hex(expected[1]))
        return out == expected[1]

    await test_decompose(dut, inputs_gen, 1, check_fn)

@cocotb.test()
async def test_sec_decompose_dilithium_44(dut):
    expected_outputs = Queue()

    async def inputs_gen():
        for i in range(TEST_CASES):
            x = [random.getrandbits(24) % Q for _ in range(4)]
            r = [random.getrandbits(24) % Q for _ in range(4)]

            await expected_outputs.put((serialize_coeffs([decompose(u, 0)[0] % Q for u in x]), serialize_coeffs([decompose(u, 0)[1] for u in x])))

            yield [serialize_coeffs([(x[i] - r[i]) % Q for i in range(4)]), serialize_coeffs(r)]

    async def check_fn(high_bits, low_bits):
        expected = await expected_outputs.get()

        # low bits
        out = 0
        for i in range(4):
            out += (((((low_bits[0] >> (i * 24)) & 0xffffff) + (low_bits[1] >> (i * 24)) & 0xffffff)) % Q) << (i * 24)

        # print(hex(out), hex(expected[0]))
        if out != expected[0]:
            return False

        # high bits
        out = 0
        for i in range(4):
            out += ((high_bits >> (i * 6)) & 0x3f) << (i * 24)

        # print(hex(out), hex(expected[1]))
        return out == expected[1]

    await test_decompose(dut, inputs_gen, 0, check_fn)

if __name__  == '__main__':
    run_tests('sec_decompose_top', 'tests.masking.sec_decompose_tb')
