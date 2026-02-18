import random
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge
from os import urandom

from tests.dilithium.dilithium import *
from tests.utils import *

TEST_CASES = 100

async def sample_inputs(dut, inputs, mode):
    dut.s_axis_tuser.value = mode
    dut.mode.value = 1 - (mode & 0x1)

    for (x, y) in inputs:
        while len(x) % 8 != 0:
            x += b'\x00'
            y += b'\x00'

        for i in range(0, len(x), 8):
            dut.s_axis_tdata.value = [int.from_bytes(y[i: i + 8], 'little'), int.from_bytes(x[i: i + 8], 'little')]
            dut.s_axis_tvalid.value = 1

            await RisingEdge(dut.clk)

            while dut.s_axis_tready.value != 1:
                await RisingEdge(dut.clk)

            dut.s_axis_tvalid.value = 0

            if i != len(x) - 8:
                for _ in range(random.randint(0, 5)):
                    await RisingEdge(dut.clk)

        while (dut.m_axis_tvalid.value and dut.m_axis_tlast.value and dut.m_axis_tready.value) == 0:
            dut.s_axis_tdata.value = [0, 0]
            dut.s_axis_tvalid.value = 1
            await RisingEdge(dut.clk)

        dut.s_axis_tvalid.value = 0

        for _ in range(random.randint(1, 5)):
            await RisingEdge(dut.clk)

    dut.s_axis_tdata.value = [0, 0]
    dut.s_axis_tvalid.value = 0

async def test_sample(dut, mode, inputs, outputs):
    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    cocotb.start_soon(send_randomness(dut.sec_conversion_random, dut.clk, 776, dut.sec_conversion_random_mode, Q))
    cocotb.start_soon(send_randomness(dut.other_random, dut.clk, 25))
    cocotb.start_soon(sample_inputs(dut, inputs, mode))

    dut.m_axis_tready.value = 1

    await RisingEdge(dut.clk)

    for o in outputs:
        for i in range(0, 256, 4):
            while dut.m_axis_tvalid.value != 1:
                await RisingEdge(dut.clk)

            # print(dut.m_axis_tdata.value[0].buff.hex())
            # print(dut.m_axis_tdata.value[1].buff.hex())
            # print(unmask_arithmetic(dut.m_axis_tdata.value, 4).to_bytes(12, 'big').hex())
            # print(serialize_coeffs(o[i:i+4]).to_bytes(12, 'big').hex())
            assert unmask_arithmetic(dut.m_axis_tdata.value, 4) == serialize_coeffs(o[i:i+4])

            dut.m_axis_tready.value = 0

            for _ in range(random.randint(0, 5)):
                await RisingEdge(dut.clk)

            dut.m_axis_tready.value = 1

            await RisingEdge(dut.clk)

@cocotb.test()
async def test_sample_ntt(dut):
    inputs = []
    outputs = []

    for _ in range(TEST_CASES):
        i = b'', b''
        o = []
        while len(o) < 256:
            x = urandom(6)
            sample_ntt(x, o)

            i = (i[0] + x, i[1] + b'\x00\x00\x00')

        inputs.append(i)
        outputs.append(o)

    await test_sample(dut, 4, inputs, outputs)

@cocotb.test()
async def test_sample_bounded2(dut):
    inputs = []
    outputs = []

    for _ in range(TEST_CASES):
        i0, i1 = b'', b''
        o = []
        while len(o) < 256:
            x = urandom(1), urandom(1)
            sample_bounded2(unmask_boolean(x), o)

            i0 += x[0]
            i1 += x[1]

        inputs.append((i0, i1))
        outputs.append(o)

    await test_sample(dut, 5, inputs, outputs)

@cocotb.test()
async def test_sample_bounded4(dut):
    inputs = []
    outputs = []

    for _ in range(TEST_CASES):
        i0, i1 = b'', b''
        o = []
        while len(o) < 256:
            x = urandom(1), urandom(1)
            sample_bounded4(unmask_boolean(x), o)

            i0 += x[0]
            i1 += x[1]

        inputs.append((i0, i1))
        outputs.append(o)

    await test_sample(dut, 6, inputs, outputs)

if __name__ == "__main__":
    run_tests('sample_top', 'tests.dilithium.sample_tb')
