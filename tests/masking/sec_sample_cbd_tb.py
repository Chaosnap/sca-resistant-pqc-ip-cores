import random
from os import urandom

import cocotb
from cocotb.queue import Queue
from cocotb.triggers import RisingEdge

from tests.utils import *
from tests.kyber.kyber import Q, sample_cbd2, sample_cbd3

TEST_CASES = 1000

def prepare_input(x, cbd3):
    x = int.from_bytes(x, 'little')

    if cbd3:
        return x

    y = 0

    for i in range(8):
        tmp = (x >> (4 * i)) & 0xf
        tmp = (tmp & 0x3) + (((tmp >> 2) & 0x3) << 3)

        y += tmp << (6 * i)

    return y

async def send_inputs(dut, inputs, cbd3):
    step = 6 if cbd3 else 4
    for (x, y) in inputs:
        for i in range(0, len(x), step):
            dut.s_axis_tdata.value = [prepare_input(y[i: i + step], cbd3), prepare_input(x[i: i + step], cbd3)]
            dut.s_axis_tvalid.value = 1

            await RisingEdge(dut.clk)

            await wait_for_signal(dut.clk, dut.s_axis_tready)

            dut.s_axis_tvalid.value = 0

            await wait_for_random_delay(dut.clk)

    dut.s_axis_tdata.value = [0, 0]
    dut.s_axis_tvalid.value = 0

def unmask_and_add_one(x):
    x = x[0].integer ^ x[1].integer

    arr = []
    for _ in range(8):
        # arr.append(((x & 0x3) - (x & 0x4) + 1) % Q)
        arr.append(((x & 0x7) - 3) % Q)
        x >>= 3

    return serialize_coeffs(arr)


async def test_sample_cbd(dut, cbd3, inputs, outputs):
    await initialize_component(dut)

    cocotb.start_soon(send_randomness(dut.random, dut.clk, 18))
    cocotb.start_soon(send_inputs(dut, inputs, cbd3))

    for o in outputs:
        for i in range(0, 256, 8):
            await wait_for_signal(dut.clk, dut.coeffs_vld)

            # print(hex(serialize_coeffs(o[i:i+8])))
            # print(hex(unmask_and_add_one(dut.coeffs.value)))

            assert unmask_and_add_one(dut.coeffs.value) == serialize_coeffs(o[i:i+8])

            await RisingEdge(dut.clk)

@cocotb.test()
async def test_sample_cbd2(dut):
    inputs = []
    outputs = []

    for _ in range(TEST_CASES):
        i = urandom(128), urandom(128)

        inputs.append(i)
        outputs.append(sample_cbd2(unmask_boolean(i)))

    await test_sample_cbd(dut, False, inputs, outputs)

@cocotb.test()
async def test_sample_cbd3(dut):
    inputs = []
    outputs = []

    for _ in range(TEST_CASES):
        i = urandom(192), urandom(192)

        inputs.append(i)
        outputs.append(sample_cbd3(unmask_boolean(i)))

    await test_sample_cbd(dut, True, inputs, outputs)

if __name__ == '__main__':
    run_tests('sec_sample_cbd', 'tests.masking.sec_sample_cbd_tb')
