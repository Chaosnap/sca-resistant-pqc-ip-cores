import random
import cocotb
from cocotb.clock import Clock, Timer
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge
from cocotb.utils import get_sim_time
from os import urandom
import copy

from tests.dilithium.dilithium import *
from tests.utils import *

import hashlib

TEST_CASES = 1

async def data_checks(dut, sk, pk, sig, msg, sec_level):
    while dut.seed_vld.value == 1:
        await RisingEdge(dut.clk)

    await check_data(dut, dut.seed_vld, pk[:32])

    while dut.in_state_machine.state.value != 9:
        await RisingEdge(dut.clk)

    c_len = 32 if sec_level == 2 else 48 if sec_level == 3 else 64
    await check_data(dut, dut.seed_vld, pk[:32] + 160 * b'\x00' + sig[:c_len])

    await check_data(dut, dut.tr_vld, pk[:32] + 32 * b'\x00' + sk[64:128] + 64 * b'\x00' + sig[:c_len])

    await check_data(dut, dut.mu_vld, pk[:32] + 32 * b'\x00' + mu(sk, msg) + 64 * b'\x00' + sig[:c_len])

    print('data finished')

async def bram0_checks(dut, pk, sig, msg, sec_level):
    k, l = k_l(sec_level)
    poly_offset = 0

    t1 = unpack_pk(pk, sec_level)
    z, h = unpack_sig(sig, sec_level)

    a = expand_a(pk[:32], sec_level)

    for i in range(k):
        await check_memory(dut, dut.bram0, t1[i].to_numpy(), 4, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset)
        poly_offset = (poly_offset + 1) % 8

    for i in range(l):
        await check_memory(dut, dut.bram0, z[i].to_numpy(), 4, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset)
        poly_offset = (poly_offset + 1) % 8

    for i in range(l):
        for j in range(k):
            await check_memory(dut, dut.bram0, a[j][i].to_numpy(), 4, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset)
            poly_offset = (poly_offset + 1) % 8

    c_len = 32 if sec_level == 2 else 48 if sec_level == 3 else 64
    _, c = sample_in_ball(sig[:c_len], sec_level)

    await check_memory(dut, dut.bram0, c, 4, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset)
    poly_offset = (poly_offset + 1) % 8

    await check_memory(dut, dut.bram0, ntt(np.array(c)), 4, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset)

    print('bram0 finished')

async def bram1_checks(dut, pk, sig, msg, sec_level):
    k, l = k_l(sec_level)

    async def wait_for_vld_addr(offset):
        while not (dut.bram1.wea.value == 1 and dut.poly_mul0.vld == 1 and dut.bram1.addra.value == (offset + 1) * 64 - 1):
            await RisingEdge(dut.clk)

    a = expand_a(pk[:32], sec_level)

    t1 = unpack_pk(pk, sec_level)
    z, h = unpack_sig(sig, sec_level)

    t1_ntt = []
    z_ntt = []

    for i in range(k):
        await wait_for_vld_addr(i)
        t1_ntt.append(ntt(t1[i].to_numpy()))
        await check_memory(dut, dut.bram1, t1_ntt[-1], 4, poly_offset=i)

    w_ntt = [np.zeros((256, ), dtype=np.int32) for _ in range(k)]

    for i in range(l):
        await wait_for_vld_addr(k + i)
        z_ntt.append(ntt(z[i].to_numpy()))
        await check_memory(dut, dut.bram1, z_ntt[-1], 4, poly_offset=k + i)

    for i in range(l):
        for j in range(k):
            w_ntt[j] = barrett_reduce(w_ntt[j] + z_ntt[i] * a[j][i].to_numpy())

            await wait_for_vld_addr(2 * (l + k) + j)
            await check_memory(dut, dut.bram1, w_ntt[j], 4, poly_offset=2 * (l + k) + j)

    c_len = 32 if sec_level == 2 else 48 if sec_level == 3 else 64
    _, c = sample_in_ball(sig[:c_len], sec_level)
    c = ntt(np.array(c))

    for i in range(k):
        w_ntt[i] = barrett_reduce(w_ntt[i] - c * t1_ntt[i])

        await wait_for_vld_addr(2 * (l + k) + i)
        await check_memory(dut, dut.bram1, w_ntt[i], 4, poly_offset=2 * (l + k) + i)

        await wait_for_vld_addr(2 * (l + k) + i)
        await check_memory(dut, dut.bram1, intt(w_ntt[i]), 4, poly_offset=2 * (l + k) + i)


    for _ in range(1000):
        await RisingEdge(dut.clk)

    print('bram1 finished')


async def test_dilithium_verify(dut, sec_level):
    await initialize_component(dut)

    for _ in range(TEST_CASES):
        mode = 0b00100000000 if sec_level == 2 else 0b01100000000 if sec_level == 3 else 0b10100000000

        pk, sk, _ = key_pair(sec_level)
        ctx = urandom(random.randint(1, 255))
        msg = urandom(random.randint(1, 800))
        sig = sign(sk, msg, ctx, sec_level)

        msg = b'\x00' + len(ctx).to_bytes(1, 'little') + ctx + msg

        valid = True

        # if random.random() < 0.5:
        #     sig = bytearray(sig)
        #     valid = False

        #     k, l = k_l(sec_level)

        #     c_len = 32 if sec_level == 2 else 48 if sec_level == 3 else 64
        #     z_packed = 576 if sec_level == 2 else 640
        #     omega = 80 if sec_level == 2 else 55 if sec_level == 3 else 75

        #     r = random.random()
        #     if r < 0.33:
        #         print('changing c')
        #         index = random.randint(0, c_len - 1)
        #     # TODO: support invalid z tests
        #     else:
        #         print('changing hint')
        #         index = c_len + l * z_packed + random.randint(0, omega + k - 1)

        #     sig[index] = (sig[index] + random.randint(1, 255)) % 256
        #     sig = bytes(sig)

        inputs = pk + sig + msg

        # add padding to message
        inputs += b'\x1f'

        # make sure it is aligned to 8B
        while len(inputs) % 8 != 0:
            inputs += b'\x00'

        cocotb.start_soon(sample_inputs(dut, split_to_transactions(inputs), mode))

        await RisingEdge(dut.clk)

        cocotb.start_soon(bram0_checks(dut, pk, sig, msg, sec_level)),
        cocotb.start_soon(bram1_checks(dut, pk, sig, msg, sec_level)),
        cocotb.start_soon(data_checks(dut, sk, pk, sig, msg, sec_level))

        dut.m_axis_tready.value = 1
        await RisingEdge(dut.clk)

        while dut.m_axis_tvalid.value == 0:
            await RisingEdge(dut.clk)

        assert dut.m_axis_tdata.value[1] == (1 if valid else 0)

        dut.m_axis_tready.value = 0


@cocotb.test()
async def test_dilithium_verify2(dut):
    await test_dilithium_verify(dut, 2)

@cocotb.test()
async def test_dilithium_verify3(dut):
    await test_dilithium_verify(dut, 3)

@cocotb.test()
async def test_dilithium_verify5(dut):
    await test_dilithium_verify(dut, 5)


if __name__ == "__main__":
    run_tests('top', 'tests.dilithium.verify_tb', parameters={'SIMULATION': True})
