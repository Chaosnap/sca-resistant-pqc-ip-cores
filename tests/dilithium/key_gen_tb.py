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

TEST_CASES = 1

async def data_checks(dut, seed, sk, sec_level):
    await check_data(dut, dut.seed_vld, seed)

    expanded_seed = expand_seed(seed, sec_level)
    await check_data(dut, dut.seeds_vld, expanded_seed[:32] + b'\x00' * 96 + expanded_seed[32:])

    print('data finished')

async def bram0_checks(dut, seed, sk, sec_level):
    k, l = k_l(sec_level)
    poly_offset = 0

    data = expand_seed(seed, sec_level)
    t0, s1, s2 = unpack_sk(sk, sec_level)
    a = expand_a(data[:32], sec_level)

    for i in range(l):
        await check_memory(dut, dut.bram0, s1[i].to_numpy(), 4, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset, masked=True)
        poly_offset = (poly_offset + 1) % 8

        for j in range(k):
            await check_memory(dut, dut.bram0, a[j][i].to_numpy(), 4, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset)
            poly_offset = (poly_offset + 1) % 8

    for i in range(k):
        await check_memory(dut, dut.bram0, s2[i].to_numpy(), 4, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset, masked=True)
        poly_offset = (poly_offset + 1) % 8

    print('bram0 finished')

async def bram1_checks(dut, seed, sk, sec_level):
    k, l = k_l(sec_level)
    t0, s1, s2 = unpack_sk(sk, sec_level)
    data = expand_seed(seed, sec_level)
    a = expand_a(data[:32], sec_level)

    async def wait_for_vld_addr(offset):
        while not (dut.bram1.wea.value == 1 and dut.poly_mul0.vld == 1 and dut.bram1.addra.value == (offset + 1) * 64 - 1):
            await RisingEdge(dut.clk)


    t_ntt = [np.zeros((256, ), dtype=np.int32) for _ in range(k)]
    s1_ntt = []

    for i in range(l):
        await wait_for_vld_addr(l + k + i)
        s1_ntt.append(ntt(s1[i].to_numpy()))
        await check_memory(dut, dut.bram1, s1_ntt[-1], 4, poly_offset=l + k + i, masked=True)

        for j in range(k):
            t_ntt[j] = barrett_reduce(t_ntt[j] + s1_ntt[-1] * a[j][i].to_numpy())

            await wait_for_vld_addr(2 * (l + k) + j)
            await check_memory(dut, dut.bram1, t_ntt[j], 4, poly_offset=2 * (l + k) + j, masked=True)

    t = compute_w_t(a, s1, sec_level)

    for i in range(k):
        await wait_for_vld_addr(2 * (l + k) + i)
        await check_memory(dut, dut.bram1, t[i].to_numpy(), 4, poly_offset=2 * (l + k) + i, masked=True)

    print('bram1 finished')


async def test_dilithium_key_gen(dut, sec_level):
    await initialize_component(dut)

    cocotb.start_soon(send_randomness(dut.sec_conversion_random, dut.clk, 776, dut.sec_conversion_random_mode, Q))
    cocotb.start_soon(send_randomness(dut.other_random, dut.clk, 25))

    for _ in range(TEST_CASES):
        mode = 0b00001000000 if sec_level == 2 else 0b01001000000 if sec_level == 3 else 0b10001000000

        pk, sk, seed = key_pair(sec_level)

        seed_t = split_to_transactions(seed, masked=True)

        cocotb.start_soon(sample_inputs(dut, seed_t, mode))

        await RisingEdge(dut.clk)

        cocotb.start_soon(bram0_checks(dut, seed, sk, sec_level)),
        cocotb.start_soon(bram1_checks(dut, seed, sk, sec_level)),
        cocotb.start_soon(data_checks(dut, seed, sk, sec_level))

        dut.m_axis_tready.value = 1
        await RisingEdge(dut.clk)

        for i in range(0, len(pk), 8):
            while dut.m_axis_tvalid.value != 1:
                await RisingEdge(dut.clk)

            # print(dut.m_axis_tdata.value[1].buff.hex())
            # print(pk[i:i+8][::-1].hex())
            # print(i // 8, len(pk) // 8)
            assert dut.m_axis_tdata.value[1].buff == pk[i:i+8][::-1]

            dut.m_axis_tready.value = 0

            await wait_for_random_delay(dut.clk)

            dut.m_axis_tready.value = 1

            await RisingEdge(dut.clk)

        for i in range(0, len(sk), 8):
            while dut.m_axis_tvalid.value != 1:
                await RisingEdge(dut.clk)

            # print(unmask_b(dut.m_axis_tdata.value).hex())
            # print(sk[i:i+8][::-1].hex())
            # print(i // 8)
            assert unmask_b(dut.m_axis_tdata.value) == sk[i:i+8][::-1]

            dut.m_axis_tready.value = 0

            await wait_for_random_delay(dut.clk)

            dut.m_axis_tready.value = 1

            await RisingEdge(dut.clk)


@cocotb.test()
async def test_dilithium_key_gen2(dut):
    await test_dilithium_key_gen(dut, 2)

@cocotb.test()
async def test_dilithium_key_gen3(dut):
    await test_dilithium_key_gen(dut, 3)

@cocotb.test()
async def test_dilithium_key_gen5(dut):
    await test_dilithium_key_gen(dut, 5)


if __name__ == "__main__":
    run_tests('top', 'tests.dilithium.key_gen_tb', parameters={'SIMULATION': True})
