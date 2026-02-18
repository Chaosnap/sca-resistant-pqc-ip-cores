import random

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, RisingEdge

from tests.utils import *
from tests.kyber.kyber import *

TEST_CASES = 10

async def send_inputs(dut, inputs_gen, mode=None):
    if mode != None:
        dut.s_axis_tuser.value = mode

    async for x in inputs_gen():
        if x == 'wait':
            await wait_for_signal(dut.clk, dut.invalid_vld)
            continue

        dut.s_axis_tdata.value = x
        dut.s_axis_tvalid.value = 1

        await wait_for_signal(dut.clk, dut.s_axis_tready)

        dut.s_axis_tvalid.value = 0

        await wait_for_random_delay(dut.clk)

    dut.s_axis_tdata.value = [0, 0]
    if mode != None:
        dut.s_axis_tuser.value = 0
    dut.s_axis_tvalid.value = 0

async def test_sec_decompressed_comparison(dut, inputs_gen, mode, invalid):
    await initialize_component(dut)

    cocotb.start_soon(send_randomness(dut.sec_conversion_random, dut.clk, 776, dut.sec_conversion_random_mode, Q))
    cocotb.start_soon(send_randomness(dut.other_random, dut.clk, 8))
    cocotb.start_soon(send_inputs(dut, inputs_gen, mode))

    for _ in range(TEST_CASES):
        await wait_for_signal(dut.clk, dut.invalid_vld)

        assert dut.invalid.value == invalid

def make_inputs_gen(multiplier, correct):
    async def inputs_gen():
        for _ in range(TEST_CASES):
            for i in range(multiplier * 32):
                x = [random.getrandbits(12) % Q for _ in range(8)]
                r = [random.getrandbits(12) % Q for _ in range(8)]

                compress_level = (11 if multiplier == 5 else 10) if i < (multiplier - 1) * 32 else (5 if multiplier == 5 else 4)

                if correct:
                    yield [serialize_coeffs([0 for _ in range(8)]), serialize_coeffs([decompress(compress(v, compress_level), compress_level) for v in x])]
                else:
                    yield [serialize_coeffs([0 for _ in range(8)]), serialize_coeffs([decompress(compress(random.getrandbits(12) % Q, compress_level), compress_level) for _ in range(8)])]

                yield [serialize_coeffs(r), serialize_coeffs([(x[i] - r[i]) % Q for i in range(8)])]
            yield 'wait'
    return inputs_gen

@cocotb.test()
async def test_sec_decompressed_comparison_512_correct(dut):
    await test_sec_decompressed_comparison(dut, make_inputs_gen(3, True), 0, 0)

@cocotb.test()
async def test_sec_decompressed_comparison_512_incorrect(dut):
    await test_sec_decompressed_comparison(dut, make_inputs_gen(3, False), 0, 1)

@cocotb.test()
async def test_sec_decompressed_comparison_768_correct(dut):
    await test_sec_decompressed_comparison(dut, make_inputs_gen(4, True), 1, 0)

@cocotb.test()
async def test_sec_decompressed_comparison_768_incorrect(dut):
    await test_sec_decompressed_comparison(dut, make_inputs_gen(4, False), 1, 1)

@cocotb.test()
async def test_sec_decompressed_comparison_1024_correct(dut):
    await test_sec_decompressed_comparison(dut, make_inputs_gen(5, True), 2, 0)

@cocotb.test()
async def test_sec_decompressed_comparison_1024_incorrect(dut):
    await test_sec_decompressed_comparison(dut, make_inputs_gen(5, False), 2, 1)

if __name__  == '__main__':
    run_tests('sec_decompressed_comparison_top', 'tests.masking.sec_decompressed_comparison_tb')
