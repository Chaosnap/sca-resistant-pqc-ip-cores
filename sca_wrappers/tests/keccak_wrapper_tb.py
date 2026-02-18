import os
import random
import hashlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from tests.kyber.kyber import compress
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

def gen_io():
    inputs, outputs = b'', b''

    for _ in range(1):
        x, r = os.urandom(7), os.urandom(8)

        outputs += hashlib.shake_128(x).digest(8)
        x += b'\x1f'

        x = (int.from_bytes(x, 'little') ^ int.from_bytes(r, 'little')).to_bytes(8, 'little')
        inputs += x
        inputs += r

    return inputs, outputs

def unmask(x):
    return (int.from_bytes(x[:8], 'little') ^ int.from_bytes(x[8:], 'little')).to_bytes(8, 'little')

@cocotb.test()
async def test_keccak_wrapper(dut):
    clk = Clock(dut.clk, 0.333, units='us')
    cocotb.start_soon(clk.start())

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1

    for _ in range(1):
        dut.uart_rx.value = 1

        await write_byte(dut, 0x01)
        await write_byte(dut, 0x01)

        inputs, expected_outputs = gen_io()

        await write_bytes(dut, inputs)

        outputs = unmask(await read_bytes(dut, 2 * len(expected_outputs)))

        print(expected_outputs.hex())
        print(outputs.hex())
        assert outputs == expected_outputs

    await ClockCycles(dut.clk, 1024)

if __name__ == '__main__':
    run_tests('keccak_wrapper', 'sca_wrappers.tests.keccak_wrapper_tb', parameters={'UART_CYCLES_PER_BIT': CYCLES_PER_BIT, 'MASKING_EN': True}, save_vcd=True)
