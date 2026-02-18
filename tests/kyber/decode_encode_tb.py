import random
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge, FallingEdge
from os import urandom

from tests.kyber.kyber import *
from tests.utils import *

TEST_CASES = 100

settings = [(0, 384), (1, 352), (2, 320), (3, 160), (4, 128), (5, 32)]

async def sample_inputs(dut, inputs, mode):
    dut.dec_mode.value = mode
    dut.enc_mode.value = mode

    for i in range(0, len(inputs), 8):
        dut.s_axis_tdata.value = int.from_bytes(inputs[i: i + 8], 'little')
        dut.s_axis_tvalid.value = 1

        await RisingEdge(dut.clk)

        while dut.s_axis_tready.value != 1:
            await RisingEdge(dut.clk)

        dut.s_axis_tvalid.value = 0

        for _ in range(random.randint(0, 5)):
            await RisingEdge(dut.clk)

    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0

@cocotb.test()
async def test_decode_encode(dut):
    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    for _ in range(TEST_CASES):
        mode, bytes_len = random.choice(settings)
        data = urandom(bytes_len)

        cocotb.start_soon(sample_inputs(dut, data, mode))

        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)

        dut.m_axis_tready.value = 1

        for i in range(0, len(data), 8):
            while dut.m_axis_tvalid.value != 1:
                await RisingEdge(dut.clk)

            assert dut.m_axis_tdata.value.integer.to_bytes(8, 'little') == data[i: i + 8]

            await RisingEdge(dut.clk)

if __name__ == "__main__":
    run_tests('decode_encode_top', 'tests.kyber.decode_encode_tb')
