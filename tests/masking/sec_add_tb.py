import random

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, RisingEdge

from tests.utils import *

TEST_CASES = 1000

async def send_inputs(dut, inputs_gen):
    async for (x, y) in inputs_gen():
        dut.x.value = x
        dut.y.value = y
        dut.vld_in.value = 1

        dut.r.value = [random.getrandbits(26) for _ in range(14)]
        dut.r.value = [0 for _ in range(14)]

        await RisingEdge(dut.clk)

    dut.x.value = [0, 0]
    dut.y.value = [0, 0]
    dut.vld_in.value = 0

async def test_sec_add(dut, inputs_gen, check_fn):
    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    await ClockCycles(dut.clk, 3)

    cocotb.start_soon(send_inputs(dut, inputs_gen))

    for _ in range(TEST_CASES):
        await wait_for_signal(dut.clk, dut.vld_out)

        assert await check_fn(dut.z.value)

@cocotb.test()
async def test_sec_add_dilithium(dut):
    expected_outputs = Queue()

    async def inputs_gen():
        for _ in range(TEST_CASES):
            x, y = random.getrandbits(24), random.getrandbits(24)
            r_x, r_y = random.getrandbits(24), random.getrandbits(24)

            await expected_outputs.put((x + y) & 0xffffff)

            yield [x ^ r_x, r_x], [y ^ r_y, r_y]

    async def check_fn(z):
        return (z[0] ^ z[1]) & 0xffffff == await expected_outputs.get()

    await test_sec_add(dut, inputs_gen, check_fn)

@cocotb.test()
async def test_sec_add_kyber(dut):
    expected_outputs = Queue()

    async def inputs_gen():
        for _ in range(TEST_CASES):
            x, y = random.getrandbits(12) + (random.getrandbits(12) << 13), random.getrandbits(12) + (random.getrandbits(12) << 13)
            r_x, r_y = random.getrandbits(12) + (random.getrandbits(12) << 13), random.getrandbits(12) + (random.getrandbits(12) << 13)

            await expected_outputs.put((x + y) & 0x1ffefff)

            yield [x ^ r_x, r_x], [y ^ r_y, r_y]

    async def check_fn(z):
        return (z[0] ^ z[1]) & 0x1ffefff == await expected_outputs.get()

    await test_sec_add(dut, inputs_gen, check_fn)

if __name__  == '__main__':
    run_tests('sec_add', 'tests.masking.sec_add_tb', parameters={'W': 26})
