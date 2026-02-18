import random

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, RisingEdge

from tests.utils import *

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

async def test_sec_conversion(dut, inputs_gen, mode, check_fn):
    await initialize_component(dut)

    cocotb.start_soon(send_randomness(dut.random, dut.clk, 776, dut.random_mode, 0xd01 if mode < 8 else 0x7fe001))
    cocotb.start_soon(send_inputs(dut, inputs_gen, mode))

    dut.m_axis_tready.value = 0

    await ClockCycles(dut.clk, random.randint(0, 200))

    dut.m_axis_tready.value = 1
    for _ in range(TEST_CASES):
        await wait_for_signal(dut.clk, dut.m_axis_tvalid)

        assert await check_fn(dut.m_axis_tdata.value)

        dut.m_axis_tready.value = 0

        await ClockCycles(dut.clk, random.randint(0, 40))

        dut.m_axis_tready.value = 1

@cocotb.test()
async def test_sec_a2b_kyber(dut):
    expected_outputs = Queue()

    async def inputs_gen():
        for _ in range(TEST_CASES):
            x = [random.getrandbits(12) % 0xd01 for _ in range(8)]
            r = [random.getrandbits(12) % 0xd01 for _ in range(8)]

            await expected_outputs.put(serialize_coeffs(x))

            yield [serialize_coeffs([(x[i] - r[i]) % 0xd01 for i in range(8)]), serialize_coeffs(r)]

    async def check_fn(z):
        expected = await expected_outputs.get()
        # print(hex(z[0] ^ z[1]), hex(expected))
        return (z[0] ^ z[1]) == expected

    await test_sec_conversion(dut, inputs_gen, 0, check_fn)

@cocotb.test()
async def test_sec_b2a_kyber(dut):
    expected_outputs = Queue()

    async def inputs_gen():
        for _ in range(TEST_CASES):
            x = [random.getrandbits(12) % 0xd01 for _ in range(8)]
            r = [random.getrandbits(12) % 0xd01 for _ in range(8)]

            await expected_outputs.put(serialize_coeffs(x))

            yield [serialize_coeffs([x[i] ^ r[i] for i in range(8)]), serialize_coeffs(r)]

    async def check_fn(z):
        expected = await expected_outputs.get()

        out = 0
        for i in range(8):
            out += ((((z[0] >> (i * 12)) & 0xfff) + ((z[1] >> (i * 12)) & 0xfff)) % 0xd01) << (i * 12)

        # print(hex(out), hex(expected))
        return out == expected

    await test_sec_conversion(dut, inputs_gen, 4, check_fn)

@cocotb.test()
async def test_sec_a2b_dilithium(dut):
    expected_outputs = Queue()

    async def inputs_gen():
        for _ in range(TEST_CASES):
            x = [random.getrandbits(24) % 0x7fe001 for _ in range(4)]
            r = [random.getrandbits(24) % 0x7fe001 for _ in range(4)]

            await expected_outputs.put(serialize_coeffs(x))

            yield [serialize_coeffs([(x[i] - r[i]) % 0x7fe001 for i in range(4)]), serialize_coeffs(r)]

    async def check_fn(z):
        expected = await expected_outputs.get()
        # print(hex(z[0] ^ z[1]), hex(expected))
        return (z[0] ^ z[1]) == expected

    await test_sec_conversion(dut, inputs_gen, 8, check_fn)

@cocotb.test()
async def test_sec_a2b_dilithium_no_modular_reduction(dut):
    expected_outputs = Queue()

    async def inputs_gen():
        for _ in range(TEST_CASES):
            x = [random.getrandbits(24) % 0x7fe001 for _ in range(4)]
            r = [random.getrandbits(24) % 0x7fe001 for _ in range(4)]

            await expected_outputs.put(serialize_coeffs([((x[i] - r[i]) % 0x7fe001 + r[i] + (1 << 24) - 0x7fe001) & 0xffffff for i in range(4)]))

            yield [serialize_coeffs([(x[i] - r[i]) % 0x7fe001 for i in range(4)]), serialize_coeffs(r)]

    async def check_fn(z):
        expected = await expected_outputs.get()

        # print(hex((z[0] ^ z[1])), hex(expected))
        return (z[0] ^ z[1]) == expected

    await test_sec_conversion(dut, inputs_gen, 9, check_fn)

@cocotb.test()
async def test_sec_b2a_dilithium(dut):
    expected_outputs = Queue()

    async def inputs_gen():
        for i in range(TEST_CASES):
            x = [random.getrandbits(24) % 0x7fe001 for _ in range(4)]
            r = [random.getrandbits(24) % 0x7fe001 for _ in range(4)]

            await expected_outputs.put(serialize_coeffs(x))

            yield [serialize_coeffs([x[i] ^ r[i] for i in range(4)]), serialize_coeffs(r)]

    async def check_fn(z):
        expected = await expected_outputs.get()

        out = 0
        for i in range(4):
            out += (((((z[0] >> (i * 24)) & 0xffffff) + (z[1] >> (i * 24)) & 0xffffff)) % 0x7fe001) << (i * 24)

        # print(hex(out), hex(expected))
        return out == expected

    await test_sec_conversion(dut, inputs_gen, 12, check_fn)

if __name__  == '__main__':
    run_tests('sec_conversion', 'tests.masking.sec_conversion_tb')
