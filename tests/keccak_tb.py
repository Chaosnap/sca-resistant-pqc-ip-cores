import cocotb
from cocotb.clock import Clock
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge

import os
import random

import hashlib

from tests.utils import *

TEST_CASES = 1

async def test_shake(dut, hash_f, padding, r, out_blocks):
    clk = Clock(dut.clk, 1, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    for _ in range(TEST_CASES):
        data = os.urandom(random.randint(0, 400))
        expected = hash_f(data, out_blocks if out_blocks < 100 else random.randint(1, 400) * 8)

        data += padding

        while len(data) % 8 != 0:
            data += b'\x00'

        for i in range(0, len(data), 8):
            mask = int.from_bytes(os.urandom(8), byteorder='little')
            dut.s_axis_tdata.value = [(int.from_bytes(data[i: i + 8], byteorder='little') ^ mask), mask]
            dut.s_axis_tlast.value = 1 if i == len(data) - 8 else 0
            dut.s_axis_tvalid.value = 1
            dut.s_axis_tuser.value = 0 if out_blocks == 168 else 1 if out_blocks == 136 else 2 if out_blocks == 32 else 3

            await RisingEdge(dut.clk)
            while dut.s_axis_tready.value != 1:
                await RisingEdge(dut.clk)

        dut.s_axis_tlast.value = 0
        dut.s_axis_tvalid.value = 0

        dut.m_axis_tready.value = 1

        for i in range(0, len(expected), 8):
            while dut.m_axis_tvalid.value != 1:
                await RisingEdge(dut.clk)

            # print(dut.m_axis_tdata.value.buff[:8][::-1].hex())
            # print(dut.m_axis_tdata.value.buff[8:][::-1].hex())
            # print(expected[i: i + 8].hex())
            assert unmask_b(dut.m_axis_tdata.value)[::-1] == expected[i: i + 8]

            if i == len(expected) - 8:
                dut.rst.value = 1

            await RisingEdge(dut.clk)

        dut.rst.value = 0
        dut.m_axis_tready.value = 0

        await RisingEdge(dut.clk)

@cocotb.test()
async def test_shake128(dut):
    await test_shake(dut, lambda x, y: hashlib.shake_128(x).digest(y), b'\x1f', 168, 168)

@cocotb.test()
async def test_shake256(dut):
    await test_shake(dut, lambda x, y: hashlib.shake_256(x).digest(y), b'\x1f', 136, 136)

@cocotb.test()
async def test_sha3_256(dut):
    await test_shake(dut, lambda x, y: hashlib.sha3_256(x).digest(), b'\x06', 136, 32)

@cocotb.test()
async def test_sha3_512(dut):
    await test_shake(dut, lambda x, y: hashlib.sha3_512(x).digest(), b'\x06', 72, 64)

if __name__ == "__main__":
    run_tests('keccak', 'tests.keccak_tb')
