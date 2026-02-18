import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from tests.utils import run_tests
from tests.dilithium.dilithium import Q, sample_bounded2, sample_bounded4

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

def gen_io(mode):
    v_i_vld, v_i_invld, v_o = 0, 0, 0

    eta = 2 if mode == 0 else 4

    for i in range(4):
        if eta == 2:
            v_i_invld += random.randint(5, 15) << (4 * i)
            v_i_vld += random.randint(0, 4) << (4 * i)
        else:
            v_i_invld += random.randint(9, 15) << (4 * i)
            v_i_vld += random.randint(0, 8) << (4 * i)

    r = random.getrandbits(16)
    v_i_invld = (r << 16) + (v_i_invld ^ r)
    r = random.getrandbits(16)
    v_o = v_i_vld
    v_i_vld = (r << 16) + (v_i_vld ^ r)

    return v_i_invld.to_bytes(4, 'little') + v_i_vld.to_bytes(4, 'little'), v_o.to_bytes(2, 'little')

def unmask(x):
    share0, share1 = int.from_bytes(x[:2], 'little'), int.from_bytes(x[2:], 'little')

    return (share0 ^ share1).to_bytes(2, 'little')

@cocotb.test()
async def test_sec_sample_bounded_wrapper(dut):
    clk = Clock(dut.clk, 0.333, units='us')
    cocotb.start_soon(clk.start())

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1

    dut.uart_rx.value = 1

    mode = 0

    await write_byte(dut, 0x01)
    await write_byte(dut, 0x01 + mode)

    inputs, expected_outputs = gen_io(mode)

    await write_bytes(dut, inputs)

    outputs = unmask(await read_bytes(dut, 2 * len(expected_outputs)))

    # print(expected_outputs.hex())
    # print(outputs.hex())
    assert outputs == expected_outputs

    await ClockCycles(dut.clk, 1024)

if __name__ == '__main__':
    run_tests('sec_sample_bounded_wrapper', 'sca_wrappers.tests.sec_sample_bounded_wrapper_tb', parameters={'UART_CYCLES_PER_BIT': CYCLES_PER_BIT, 'MASKING_EN': True}, save_vcd=True)
