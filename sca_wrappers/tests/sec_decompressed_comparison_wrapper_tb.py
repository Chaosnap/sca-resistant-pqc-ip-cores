import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from tests.kyber.kyber import *
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

def gen_io(valid):
    inputs, outputs = b'', b''

    u_i, v_i = 0, 0

    for i in range(8):
        x = random.randint(0, 0xd00)
        u_i += (decompress(compress(x, 11), 11)) << (12 * i)

        r = random.randint(0, 0xd00)

        v_i += ((random.randint(0, 0xd00) - r) % 0xd01) << (12 * i)
        v_i += r << (96 + 12 * i)

    inputs += u_i.to_bytes(24, 'little') + v_i.to_bytes(24, 'little')
    outputs += (b'\x00' if valid else b'\x01') + 11 * b'\x00'

    return inputs, outputs

@cocotb.test()
async def test_sec_decompressed_comparison_wrapper(dut):
    clk = Clock(dut.clk, 0.333, units='us')
    cocotb.start_soon(clk.start())

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1

    dut.uart_rx.value = 1

    await write_byte(dut, 0x01)
    await write_byte(dut, 0x03)

    inputs, expected_outputs = gen_io(False)

    await write_bytes(dut, inputs)

    outputs = await read_bytes(dut, 2 * len(expected_outputs))

    # print(expected_outputs.hex())
    # print(outputs[:len(expected_outputs)].hex())
    assert outputs[:len(expected_outputs)] == expected_outputs

    await ClockCycles(dut.clk, 1024)

if __name__ == '__main__':
    run_tests('sec_decompressed_comparison_wrapper', 'sca_wrappers.tests.sec_decompressed_comparison_wrapper_tb', parameters={'UART_CYCLES_PER_BIT': CYCLES_PER_BIT, 'MASKING_EN': True}, save_vcd=True)
