import random

import cocotb
from cocotb.queue import Queue
from cocotb.triggers import RisingEdge

from tests.utils import *
from tests.dilithium.dilithium import Q, sample_bounded2, sample_bounded4

TEST_CASES = 10

async def send_inputs(dut, inputs_gen):
    async for x in inputs_gen():
        dut.s_axis_tdata.value = x
        dut.s_axis_tvalid.value = 1

        await wait_for_signal(dut.clk, dut.s_axis_tready)

        dut.s_axis_tvalid.value = 0

        await wait_for_random_delay(dut.clk)

    dut.s_axis_tdata.value = [0, 0]
    dut.s_axis_tvalid.value = 0

async def test_sample_bounded(dut, mode):
    eta = 2 if mode == 0 else 4

    expected_outputs = Queue()

    async def inputs_gen():
        for _ in range(TEST_CASES):
            cnt = 0
            o = []

            while cnt < 256:
                i = [0, 0]

                for j in range(2):
                    x, r = random.getrandbits(8), random.getrandbits(8)

                    if eta == 2:
                        sample_bounded2(x.to_bytes(), o)
                    else:
                        sample_bounded4(x.to_bytes(), o)

                    i[0] += (x ^ r) << (8 * j)
                    i[1] += r << (8 * j)

                while len(o) >= 4 and cnt < 256:
                    cnt += 4
                    await expected_outputs.put(o[:4])
                    o = o[4:]

                yield i

            await wait_for_signal(dut.clk, dut.rst)
            await RisingEdge(dut.clk)
            await RisingEdge(dut.clk)


    await initialize_component(dut)

    dut.mode.value = mode

    cocotb.start_soon(send_randomness(dut.random, dut.clk, 25))
    cocotb.start_soon(send_inputs(dut, inputs_gen))

    for _ in range(TEST_CASES):
        for j in range(64):
            await wait_for_signal(dut.clk, dut.coeffs_vld)
            o = await expected_outputs.get()

            for i in range(4):
                value = (eta - (((dut.coeffs[0].value >> (4 * i)) & 0xf) ^ ((dut.coeffs[1].value >> (4 * i)) & 0xf))) % Q
                # print(j, i, hex(value), hex(o[i]))
                assert value == o[i]

            await wait_for_random_delay(dut.clk)

        dut.rst.value = 1
        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)
        dut.rst.value = 0

@cocotb.test()
async def test_sample_bounded_eta2(dut):
    await test_sample_bounded(dut, 0)

@cocotb.test()
async def test_sample_bounded_eta4(dut):
    await test_sample_bounded(dut, 1)

if __name__ == '__main__':
    run_tests('sec_sample_bounded', 'tests.masking.sec_sample_bounded_tb')
