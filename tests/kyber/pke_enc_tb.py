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

async def data_checks(dut, pk, m, r, k):
    await check_data(dut, dut.seeds_vld, pk[-32:] + b'\x00' * 96 + r)

    print('data finished')

async def bram0_checks(dut, pk, m, r, k):
    poly_offset = 0

    a = expand_a(pk[-32:], k)

    for i in range(k):
        await check_memory(dut, dut.bram0, sample_cbd(r, i, k).to_numpy(), 8, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset, masked=True)
        poly_offset = (poly_offset + 1) % 16

    for i in range(k):
        for j in range(k):
            await check_memory(dut, dut.bram0, a[j][i].to_numpy(), 8, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset)
            poly_offset = (poly_offset + 1) % 16

    for i in range(k):
        await check_memory(dut, dut.bram0, sample_cbd(r, k + i, 3).to_numpy(), 8, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset, masked=True)
        poly_offset = (poly_offset + 1) % 16

    await check_memory(dut, dut.bram0, sample_cbd(r, 2 * k, 3).to_numpy(), 8, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset, masked=True)
    poly_offset = (poly_offset + 1) % 16

    print('bram0 finished')

async def bram1_checks(dut, pk, m, r, k):
    t = unpack_pk(pk, k)
    m = unpack_m(m)

    a = expand_a(pk[-32:], k)

    async def wait_for_vld_addr(offset):
        while not (dut.bram1.wea.value == 1 and dut.poly_mul0.vld == 1 and dut.bram1.addra.value == (offset + 1) * 64 - 33):
            await RisingEdge(dut.clk)

    r_ntt = []
    for i in range(k):
        r_ntt.append(ntt(sample_cbd(r, i, k).to_numpy()))
        await wait_for_vld_addr(2 * k + 1 + i)
        await check_memory(dut, dut.bram1, r_ntt[-1], 8, poly_offset=2 * k + 1 + i, masked=True)

    for i in range(k):
        await check_memory(dut, dut.bram1, t[i].to_numpy(), 8, poly_offset=k + i)

    await check_memory(dut, dut.bram1, m, 8, poly_offset=2 * k, masked=True)

    u = np.zeros_like(r_ntt)

    for i in range(k):
        for j in range(k):
            c, d = butterfly_mul0_poly(r_ntt[j], a[j][i].to_numpy())
            z = butterfly_mul1_poly(c, d)

            await wait_for_vld_addr(5 * k + 1 + i)
            # shares of c coefficients can't be simply summed to receive correct value, for now they are just not checked
            # await check_memory(dut, dut.bram1, c, 8, poly_offset=4 * k + 1 + i)
            await check_memory(dut, dut.bram1, d, 8, poly_offset=5 * k + 1 + i, masked=True)

            u[i] = (u[i] + z) % Q
            await wait_for_vld_addr(3 * k + 1 + i)
            await check_memory(dut, dut.bram1, u[i], 8, poly_offset=3 * k + 1 + i, masked=True)

    v = np.zeros_like(r_ntt[0])

    for i in range(k):
        c, d = butterfly_mul0_poly(r_ntt[i], t[i].to_numpy())
        z = butterfly_mul1_poly(c, d)

        await wait_for_vld_addr(5 * k + 1)
        # shares of c coefficients can't be simply summed to receive correct value, for now they are just not checked
        # await check_memory(dut, dut.bram1, c, 8, poly_offset=2 * k + 1)
        await check_memory(dut, dut.bram1, d, 8, poly_offset=5 * k + 1, masked=True)

        v = (v + z) % Q

        await wait_for_vld_addr(2 * k + 1)
        await check_memory(dut, dut.bram1, v, 8, poly_offset=2 * k + 1, masked=True)

    for i in range(k):
        await wait_for_vld_addr(3 * k + 1 + i)
        await check_memory(dut, dut.bram1, intt(u[i]), 8, poly_offset=3 * k + 1 + i, masked=True)

    await wait_for_vld_addr(2 * k + 1)
    await check_memory(dut, dut.bram1, intt(v), 8, poly_offset=2 * k + 1, masked=True)


    e = sample_cbd(r, k, 3).to_numpy()

    print('bram1 finished')


async def test_kyber_pke_enc(dut, k):
    await initialize_component(dut)

    cocotb.start_soon(send_randomness(dut.sec_conversion_random, dut.clk, 776, dut.sec_conversion_random_mode, Q))
    cocotb.start_soon(send_randomness(dut.other_random, dut.clk, 25))

    for _ in range(TEST_CASES):
        mode = 0b00000000010 if k == 2 else 0b01000000010 if k == 3 else 0b10000000010

        coins = urandom(32)
        pk, _ = pke_key_pair(coins, k)
        m = urandom(32)
        r = urandom(32)
        c = pke_enc(pk, m, r, k)

        pk_t = split_to_transactions(pk)
        m_t = split_to_transactions(m, masked=True)
        r_t = split_to_transactions(r, masked=True)

        cocotb.start_soon(sample_inputs(dut, pk_t + m_t + r_t, mode))

        await RisingEdge(dut.clk)

        cocotb.start_soon(bram0_checks(dut, pk, m, r, k)),
        cocotb.start_soon(bram1_checks(dut, pk, m, r, k)),
        cocotb.start_soon(data_checks(dut, pk, m, r, k))

        dut.m_axis_tready.value = 1
        await RisingEdge(dut.clk)

        for i in range(0, len(c), 8):
            while dut.m_axis_tvalid.value != 1:
                await RisingEdge(dut.clk)

            assert dut.m_axis_tdata.value[1].buff == c[i:i+8][::-1]

            dut.m_axis_tready.value = 0

            await wait_for_random_delay(dut.clk)

            dut.m_axis_tready.value = 1

            await RisingEdge(dut.clk)


@cocotb.test()
async def test_kyber_pke_enc2(dut):
    await test_kyber_pke_enc(dut, 2)

@cocotb.test()
async def test_kyber_pke_enc3(dut):
    await test_kyber_pke_enc(dut, 3)

@cocotb.test()
async def test_kyber_pke_enc4(dut):
    await test_kyber_pke_enc(dut, 4)


if __name__ == "__main__":
    run_tests('top', 'tests.kyber.pke_enc_tb', parameters={'SIMULATION': True})
