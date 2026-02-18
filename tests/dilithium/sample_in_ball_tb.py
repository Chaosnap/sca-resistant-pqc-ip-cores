import random
import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge
from os import urandom

from tests.dilithium.dilithium import *
from tests.utils import *

TEST_CASES = 100

async def sample_input(dut, i, mode):
    for byte in i:
        dut.mode.value = mode
        dut.data_in.value = byte
        dut.data_in_vld.value = 1

        await RisingEdge(dut.clk)

        dut.data_in_vld.value = 0

        for _ in range(random.randint(0, 5)):
            await RisingEdge(dut.clk)

    dut.mode.value = 0
    dut.data_in.value = 0
    dut.data_in_vld.value = 0

async def test_sample_in_ball(dut, sec_level):
    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    for _ in range(TEST_CASES):
        i, o = sample_in_ball(urandom(32), sec_level)

        await sample_input(dut, i, 0 if sec_level == 2 else 1 if sec_level == 3 else 2)

        dut.m_axis_tready.value = 1

        await RisingEdge(dut.clk)

        for i in range(0, 256, 4):
            while dut.m_axis_tvalid.value != 1:
                await RisingEdge(dut.clk)

            assert dut.m_axis_tdata.value.buff == bytes.fromhex(f'{o[i + 3]:06x}{o[i + 2]:06x}{o[i + 1]:06x}{o[i]:06x}')

            dut.m_axis_tready.value = 0

            for _ in range(random.randint(0, 5)):
                await RisingEdge(dut.clk)

            dut.m_axis_tready.value = 1

            await RisingEdge(dut.clk)

        dut.m_axis_tready.value = 0

    # must wait here otherwise previous line does not get assigned
    await RisingEdge(dut.clk)

@cocotb.test()
async def test_sample_in_ball2(dut):
    await test_sample_in_ball(dut, 2)

@cocotb.test()
async def test_sample_in_ball3(dut):
    await test_sample_in_ball(dut, 3)

@cocotb.test()
async def test_sample_in_ball5(dut):
    await test_sample_in_ball(dut, 5)

if __name__ == "__main__":
    run_tests('sample_in_ball', 'tests.dilithium.sample_in_ball_tb')
