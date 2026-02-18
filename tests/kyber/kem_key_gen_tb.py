import random
import cocotb
from cocotb.clock import Clock, Timer
from cocotb.runner import get_runner
from cocotb.triggers import RisingEdge
from cocotb.utils import get_sim_time
from os import urandom
import copy

from tests.kyber.kyber import *
from tests.utils import *

TEST_CASES = 1

async def data_checks(dut, seed, sk, k):
    await check_data(dut, dut.seed_vld, seed)

    expanded_seed = expand_seed(seed, k)
    await check_data(dut, dut.seeds_vld, expanded_seed[:32] + b'\x00' * 64 + sk[-32:] + expanded_seed[32:])

    print('data finished')

async def bram0_checks(dut, seed, sk, k):
    poly_offset = 0
    expanded_seed = expand_seed(seed, k)

    for i in range(k):
        await check_memory(dut, dut.bram0, sample_cbd(expanded_seed[32:], i, k).to_numpy(), 8, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset, masked=True)
        poly_offset = (poly_offset + 1) % 16

    for i in range(k):
        await check_memory(dut, dut.bram0, sample_cbd(expanded_seed[32:], k + i, k).to_numpy(), 8, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset, masked=True)
        poly_offset = (poly_offset + 1) % 16

    a = expand_a(expanded_seed[:32], k)
    for i in range(k):
        for j in range(k):
            await check_memory(dut, dut.bram0, a[j][i].to_numpy(), 8, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset)
            poly_offset = (poly_offset + 1) % 16

    print('bram0 finished')

async def bram1_checks(dut, seed, sk, k):
    expanded_seed = expand_seed(seed, k)

    async def wait_for_vld_addr(offset):
        while not (dut.bram1.wea.value == 1 and dut.poly_mul0.vld == 1 and dut.bram1.addra.value == (offset + 1) * 64 - 33):
            await RisingEdge(dut.clk)

    s_ntt, e_ntt = [], []
    for i in range(k):
        s_ntt.append(ntt(sample_cbd(expanded_seed[32:], i, k).to_numpy()))
        await wait_for_vld_addr(i)
        await check_memory(dut, dut.bram1, s_ntt[-1], 8, poly_offset=i, masked=True)

    for i in range(k):
        e_ntt.append(ntt(sample_cbd(expanded_seed[32:], k + i, k).to_numpy()))
        await wait_for_vld_addr(k + i)
        await check_memory(dut, dut.bram1, e_ntt[-1], 8, poly_offset=k + i, masked=True)

    a = expand_a(expanded_seed[:32], k)

    for i in range(k):
        for j in range(k):
            c, d = butterfly_mul0_poly(s_ntt[i], a[j][i].to_numpy())
            z = butterfly_mul1_poly(c, d)

            await wait_for_vld_addr(3 * k + j)
            # shares of c coefficients can't be simply summed to receive correct value, for now they are just not checked
            # await check_memory(dut, dut.bram1, c, 8, poly_offset=2 * k + j)
            await check_memory(dut, dut.bram1, d, 8, poly_offset=3 * k + j, masked=True)

            e_ntt[j] = (e_ntt[j] + z) % Q
            await wait_for_vld_addr(k + j)
            await check_memory(dut, dut.bram1, e_ntt[j], 8, poly_offset=k + j, masked=True)

    print('bram1 finished')


async def test_kyber_key_gen(dut, k):
    await initialize_component(dut)

    cocotb.start_soon(send_randomness(dut.sec_conversion_random, dut.clk, 776, dut.sec_conversion_random_mode, Q))
    cocotb.start_soon(send_randomness(dut.other_random, dut.clk, 25))

    for _ in range(TEST_CASES):
        mode = 0b00000001000 if k == 2 else 0b01000001000 if k == 3 else 0b10000001000

        coins = urandom(64)
        pk, sk = kem_key_pair(coins, k)

        coins_t = split_to_transactions(coins, masked=True)

        cocotb.start_soon(sample_inputs(dut, coins_t, mode))

        await RisingEdge(dut.clk)

        cocotb.start_soon(bram0_checks(dut, coins[:32], sk, k)),
        cocotb.start_soon(bram1_checks(dut, coins[:32], sk, k)),
        cocotb.start_soon(data_checks(dut, coins[:32], sk, k))

        dut.m_axis_tready.value = 1
        await RisingEdge(dut.clk)

        for i in range(0, len(pk), 8):
            while dut.m_axis_tvalid.value != 1:
                await RisingEdge(dut.clk)

            # print(dut.m_axis_tdata.value.buff.hex())
            # print(pk[i:i+8][::-1].hex())
            assert dut.m_axis_tdata.value[1].buff == pk[i:i+8][::-1]

            dut.m_axis_tready.value = 0

            await wait_for_random_delay(dut.clk)

            dut.m_axis_tready.value = 1

            await RisingEdge(dut.clk)

        for i in range(0, len(sk), 8):
            while dut.m_axis_tvalid.value != 1:
                await RisingEdge(dut.clk)

            # print(dut.m_axis_tdata.value.buff.hex())
            # print(sk[i:i+8][::-1].hex())
            assert unmask_b(dut.m_axis_tdata.value) == sk[i:i+8][::-1]

            dut.m_axis_tready.value = 0

            await wait_for_random_delay(dut.clk)

            dut.m_axis_tready.value = 1

            await RisingEdge(dut.clk)


@cocotb.test()
async def test_kyber_key_gen2(dut):
    await test_kyber_key_gen(dut, 2)

@cocotb.test()
async def test_kyber_key_gen3(dut):
    await test_kyber_key_gen(dut, 3)

@cocotb.test()
async def test_kyber_key_gen4(dut):
    await test_kyber_key_gen(dut, 4)


if __name__ == "__main__":
    run_tests('top', 'tests.kyber.kem_key_gen_tb', parameters={'SIMULATION': True})
