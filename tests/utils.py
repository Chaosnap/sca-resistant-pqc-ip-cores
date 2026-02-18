import cocotb
import random
import tkinter

from cocotb.clock import Clock, Timer
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge
from cocotb.utils import get_sim_time

from functools import reduce

RANDOMIZE = 0

def get_sources(path='Modules.tcl'):
    tcl = tkinter.Tcl()

    tcl.call('set', 'ENTITY_BASE', '/Users/paprikadobi/Documents/vut/axe/kyber-opt')
    tcl.evalfile(path)

    return list(tcl.call('set', 'PACKAGES')) + list(tcl.call('set', 'MOD'))

# functions to change data representation

def mask_b(x, bits=64):
    r = random.getrandbits(bits)

    return [x ^ r, r]

def unmask_b(x, bits=64):
    return (x[0] ^ x[1]).to_bytes(bits >> 3)

def unmask_boolean(shares, count=None):
    if count != None:
        bit_size = 96 // count
        Q = 0xd01 if bit_size == 12 else 0x7fe001

        return reduce(lambda acc, x: acc + (((((shares >> (bit_size * x)) & ((1 << bit_size) - 1)) ^ ((shares >> (bit_size * x + 96)) & ((1 << bit_size) - 1))) % Q) << (bit_size * x)), range(count), 0)

    return bytes([x[0] ^ x[1] for x in zip(*shares)])

def unmask_arithmetic(shares, count=None):
    if count != None:
        bit_size = 96 // count
        Q = 0xd01 if bit_size == 12 else 0x7fe001

        return reduce(lambda acc, x: acc + (((((shares[0] >> (bit_size * x)) & ((1 << bit_size) - 1)) + ((shares[1] >> (bit_size * x)) & ((1 << bit_size) - 1))) % Q) << (bit_size * x)), range(count), 0)

    return bytes([x[0] + x[1] for x in zip(*shares)])

def serialize_coeffs(coeffs, masked = False):
    bit_size = 96 // len(coeffs)

    if masked:
        return reduce(lambda acc, x: [acc[i] + (int(x[1][(i + 1) & 0x1]) << (bit_size * x[0])) for i in range(2)], enumerate(coeffs), [0, 0])

    return reduce(lambda acc, x: acc + (int(x[1]) << (bit_size * x[0])), enumerate(coeffs), 0)

def split_to_transactions(data, masked=False):
    transactions = []

    for i in range(0, len(data), 8):
        x = int.from_bytes(data[i: i + 8], 'little')

        transactions.append(mask_b(x) if masked else [0, x])

    return transactions

# helpful functions for cocotb tests

async def wait_for_signal(clk, signal):
    await RisingEdge(clk)

    while signal.value != 1:
        await RisingEdge(clk)

async def wait_for_random_delay(clk):
    if RANDOMIZE != 0:
        for _ in range(random.randint(1, RANDOMIZE)):
            await RisingEdge(clk)

async def initialize_component(dut):
    clk = Clock(dut.clk, 0.333, units='us')
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    await RisingEdge(dut.clk)

async def send_inputs(dut, inputs_gen, mode=None):
    if mode != None:
        dut.s_axis_tuser.value = mode

    for x in inputs_gen():
        dut.s_axis_tdata.value = x
        dut.s_axis_tvalid.value = 1

        await wait_for_signal(dut.clk, dut.s_axis_tready)

        dut.s_axis_tvalid.value = 0

        await wait_for_random_delay(dut.clk)

    if x is int:
        dut.s_axis_tdata.value = 0
    else:
        dut.s_axis_tdata.value = [0, 0]

    if mode != None:
        dut.s_axis_tuser.value = 0
    dut.s_axis_tvalid.value = 0

async def send_randomness(random_signal, clock, bits, mode_signal=None, q=None, from_zero=False):
    while True:
        if q != None: # and (mode_signal == None or mode_signal.value == 1):
            r = (random.randint(1, 0xd01) << 12) + random.randint(1, 0xd01) if q == 0xd01 else random.randint(1, q)
            if from_zero:
                r -= 1
            random_signal.value = (random.getrandbits(bits - 24) << 24) + r
        else:
            random_signal.value = random.getrandbits(bits)
        await RisingEdge(clock)

async def test_component(dut, inputs_gen, outputs_gen, mode=None, output_convert_f=lambda x: x, random_bits=None):
    await initialize_component(dut)

    cocotb.start_soon(send_inputs(dut, inputs_gen, mode=mode))

    if random_bits != None:
        cocotb.start_soon(send_randomness(dut.sec_conversion_random, dut.clk, random_bits))

    for z in outputs_gen():
        dut.m_axis_tready.value = 1

        await wait_for_signal(dut.clk, dut.m_axis_tvalid)

        assert output_convert_f(dut.m_axis_tdata.value) == z

        dut.m_axis_tready.value = 0

        await wait_for_random_delay(dut.clk)

# helpful functions for top component testings

async def check_data(dut, data_vld, data, debug = False):
    while data_vld.value != 1:
        await RisingEdge(dut.clk)

    if debug:
        print(data.hex())
        print(dut.DATA_DEBUG.value.buff[::-1][:len(data)].hex())

    assert dut.DATA_DEBUG.value.buff[::-1][:len(data)] == data

async def check_memory(dut, mem, poly, coeffs_per_row, vld_sig = None, poly_offset = 0, masked = False, debug = False):
    if vld_sig != None:
        offset = poly_offset if coeffs_per_row == 8 else 2 * poly_offset
        while (vld_sig.value.integer >> offset) & 0x1 == 1:
            await RisingEdge(dut.clk)

        while (vld_sig.value.integer >> offset) & 0x1 != 1:
            await RisingEdge(dut.clk)
    else:
        poly_offset = int((coeffs_per_row / 4) * poly_offset)

    bit_size = 96 // coeffs_per_row

    for i in range(0, len(poly), coeffs_per_row):
        mem.debug_addr.value = (poly_offset * 256 + i) // coeffs_per_row
        await Timer(10, units='ns')

        if masked:
            value = unmask_arithmetic([mem.debug_data.value & 0xffffffffffffffffffffffff, mem.debug_data.value.integer >> 96], coeffs_per_row)

            if debug:
                print(mem.debug_addr.value.integer)
                print(mem.debug_data.value.buff[:12].hex())
                print(mem.debug_data.value.buff[12:].hex())
                print(value.to_bytes(12, 'big').hex())
                print(serialize_coeffs(poly[i:i + coeffs_per_row]).to_bytes(12, 'big').hex())
            assert value == serialize_coeffs(poly[i:i + coeffs_per_row])
        else:
            if debug:
                print(mem.debug_addr.value.integer)
                print(mem.debug_data.value.buff.hex())
                print(serialize_coeffs(poly[i:i + coeffs_per_row]).to_bytes(12, 'big').hex())
            assert mem.debug_data.value & 0xffffffffffffffffffffffff == serialize_coeffs(poly[i:i + coeffs_per_row])

async def sample_inputs(dut, inputs, mode):
    dut.component_mode.value = mode
    dut.component_mode_vld.value = 1

    await wait_for_signal(dut.clk, dut.component_mode_next)

    dut.component_mode.value = 0
    dut.component_mode_vld.value = 0

    for i, x in enumerate(inputs):
        dut.s_axis_tdata.value = x
        dut.s_axis_tlast.value = 1 if i == len(inputs) - 1 else 0
        dut.s_axis_tvalid.value = 1

        await wait_for_signal(dut.clk, dut.s_axis_tready)

        dut.s_axis_tvalid.value = 0

        await wait_for_random_delay(dut.clk)

    dut.s_axis_tdata.value = [0, 0]
    dut.s_axis_tlast.value = 0
    dut.s_axis_tvalid.value = 0

async def periodic_time_printer(interval_us=1000):
    while True:
        current_time = get_sim_time(units='us')
        cocotb.log.info(f'Simulation time: {current_time} us')
        await Timer(interval_us, units='us')

def run_tests(toplevel, testbench, parameters={}, seed=None, save_vcd=False):
    r = get_runner('nvc')
    r.build(vhdl_sources=get_sources(), hdl_toplevel=toplevel, build_args=['--ieee-warnings=off'], always=True, parameters=parameters)
    r.test(hdl_toplevel=toplevel, test_module=testbench, seed=seed, plusargs=['--dump-arrays', '--wave=test.fst'] if save_vcd else [], parameters=parameters)
