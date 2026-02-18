import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from tests.utils import run_tests

CYCLES_PER_BIT = 6

async def write_byte(dut, value):
    await ClockCycles(dut.clk, CYCLES_PER_BIT)

    dut.uart_rx.value = 0
    await ClockCycles(dut.clk, CYCLES_PER_BIT)

    for i in range(8):
        dut.uart_rx.value = (value >> i) & 0x1
        await ClockCycles(dut.clk, CYCLES_PER_BIT)

    dut.uart_rx.value = 1

async def read_byte(dut):
    while dut.uart_tx.value != 0:
        await RisingEdge(dut.clk)

    await ClockCycles(dut.clk, CYCLES_PER_BIT)

    value = 0
    for i in range(8):
        value += dut.uart_tx.value << i
        await ClockCycles(dut.clk, CYCLES_PER_BIT)

    return value

async def write_bytes(dut, values):
    for v in values:
        await write_byte(dut, v)

async def read_bytes(dut, length):
    values = []

    for _ in range(length):
        values.append(await read_byte(dut))

    return bytes(values)

def gen_io(cbd3):
    v_i, v_o = 0, 0

    offset = 3 if cbd3 else 2

    for i in range(8):
        x = random.getrandbits(2 * offset)
        y = 3
        for j in range(offset):
            y += (x >> j) & 0x1
            y -= (x >> (offset + j)) & 0x1

        if cbd3:
            v_i += x << (i * 6)
        else:
            v_i += ((x & 0x3) + (((x >> 2) & 0x3) << 3)) << (i * 6)
        v_o += y << (i * 3)

    r = random.getrandbits(48)
    v_i = (r << 48) + (v_i ^ r)

    return v_i.to_bytes(12, 'little'), v_o.to_bytes(6, 'little')

def unmask(x):
    share0, share1 = int.from_bytes(x[:6], 'little'), int.from_bytes(x[6:], 'little')

    v = 0
    for i in range(8):
        v += ((share0 & 0x7) ^ (share1 & 0x7)) << (i * 3)

        share0 >>= 3
        share1 >>= 3

    return v.to_bytes(6, 'little')

@cocotb.test()
async def test_sec_sample_cbd_wrapper(dut):
    clk = Clock(dut.clk, 0.333, units='us')
    cocotb.start_soon(clk.start())

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1

    dut.uart_rx.value = 1

    await write_byte(dut, 0x01)
    await write_byte(dut, 0x01)

    inputs, expected_outputs = gen_io(False)

    await write_bytes(dut, inputs)

    outputs = unmask(await read_bytes(dut, 2 * len(expected_outputs)))

    # print(expected_outputs.hex())
    # print(outputs.hex())
    assert outputs == expected_outputs

    await ClockCycles(dut.clk, 1024)

if __name__ == '__main__':
    run_tests('sec_sample_cbd_wrapper', 'sca_wrappers.tests.sec_sample_cbd_wrapper_tb', parameters={'UART_CYCLES_PER_BIT': CYCLES_PER_BIT, 'MASKING_EN': True}, save_vcd=True)
