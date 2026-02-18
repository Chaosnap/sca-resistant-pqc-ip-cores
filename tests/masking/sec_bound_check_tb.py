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

async def test_bound_check(dut, mode, bound):
    invalid, expected_invalid = 0, 0
    inputs_done = False
    async def inputs_gen():
        nonlocal expected_invalid, inputs_done
        for _ in range(TEST_CASES):
            x = [random.getrandbits(24) % Q for _ in range(4)]
            r = [random.getrandbits(24) % Q for _ in range(4)]

            for v in x:
                if v >= bound and v - Q <= -bound:
                    expected_invalid += 1

            yield [serialize_coeffs([(x[i] - r[i]) % Q for i in range(4)]), serialize_coeffs(r)]
        inputs_done = True

    await initialize_component(dut)

    cocotb.start_soon(send_randomness(dut.sec_conversion_random, dut.clk, 776, dut.sec_conversion_random_mode, Q))
    cocotb.start_soon(send_inputs(dut, inputs_gen, mode))

    await ClockCycles(dut.clk, 36)

    cnt = 0
    while not inputs_done or cnt < RANDOMIZE + 40:
        if inputs_done:
            cnt += 1

        invalid += dut.sec_bound_check.debug_invalid.value

        await RisingEdge(dut.clk)

    assert invalid == expected_invalid, f'{invalid} != {expected_invalid}'

@cocotb.test()
async def test_sec_bound_check_z(dut):
    await test_bound_check(dut, 0, (1 << 17) - 78)
    await test_bound_check(dut, 4, (1 << 19) - 196)
    await test_bound_check(dut, 8, (1 << 19) - 120)

@cocotb.test()
async def test_sec_bound_check_r0(dut):
    await test_bound_check(dut, 1, (Q - 1) // 88 - 78)
    await test_bound_check(dut, 5, (Q - 1) // 32 - 196)
    await test_bound_check(dut, 9, (Q - 1) // 32 - 120)

@cocotb.test()
async def test_sec_bound_check_ct0(dut):
    await test_bound_check(dut, 2, (Q - 1) // 88)
    await test_bound_check(dut, 6, (Q - 1) // 32)
    await test_bound_check(dut, 10, (Q - 1) // 32)

if __name__  == '__main__':
    run_tests('sec_bound_check_top', 'tests.masking.sec_bound_check_tb')
