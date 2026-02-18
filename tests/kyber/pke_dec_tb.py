import random
import cocotb
from cocotb.clock import Clock, Timer
from cocotb.triggers import RisingEdge
from cocotb.utils import get_sim_time
from os import urandom
import copy

from tests.kyber.kyber import *
from tests.utils import *

TEST_CASES = 1

async def bram0_checks(dut, sk , c, k):
    poly_offset = 0
    u, v = unpack_c(c, k)

    for i in range(k):
        await check_memory(dut, dut.bram0, u[i].to_numpy(), 8, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset)
        poly_offset = (poly_offset + 1) % 16

    await check_memory(dut, dut.bram0, v.to_numpy(), 8, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset)
    poly_offset = (poly_offset + 1) % 16

    print('bram0 finished')

async def bram1_checks(dut, sk , c, k):
    s = unpack_sk(sk, k)
    u, v = unpack_c(c, k)

    async def wait_for_vld_addr(offset):
        while not (dut.bram1.wea.value == 1 and dut.poly_mul0.vld == 1 and dut.bram1.addra.value == (offset + 1) * 64 - 33):
            await RisingEdge(dut.clk)

    u_ntt = []
    for i in range(k):
        u_ntt.append(ntt(u[i].to_numpy()))
        await wait_for_vld_addr(2 * k + i)
        await check_memory(dut, dut.bram1, u_ntt[-1], 8, poly_offset=2 * k + i)

    for i in range(k):
        await check_memory(dut, dut.bram1, s[i].to_numpy(), 8, poly_offset=i, masked=True)

    w = np.zeros_like(u_ntt[0])

    for i in range(k):
        c, d = butterfly_mul0_poly(u_ntt[i], s[i].to_numpy())
        z = butterfly_mul1_poly(c, d)

        await wait_for_vld_addr(2 * k)
        # shares of c coefficients can't be simply summed to receive correct value, for now they are just not checked
        # await check_memory(dut, dut.bram1, c, 8, poly_offset=5 * k, masked=True)
        await check_memory(dut, dut.bram1, d, 8, poly_offset=2 * k, masked=True)

        w = (w + z) % Q

        await wait_for_vld_addr(2 * k)
        await check_memory(dut, dut.bram1, w, 8, poly_offset=2 * k, masked=True)

    await wait_for_vld_addr(2 * k)
    await check_memory(dut, dut.bram1, intt(w), 8, poly_offset=2 * k, masked=True)

    print('bram1 finished')


async def test_kyber_pke_dec(dut, k):
    await initialize_component(dut)

    cocotb.start_soon(send_randomness(dut.sec_conversion_random, dut.clk, 776, dut.sec_conversion_random_mode, Q))
    cocotb.start_soon(send_randomness(dut.other_random, dut.clk, 25))

    for _ in range(TEST_CASES):
        mode = 0b00000000100 if k == 2 else 0b01000000100 if k == 3 else 0b10000000100

        coins = urandom(32)
        pk, sk = pke_key_pair(coins, k)
        m = urandom(32)
        r = urandom(32)
        c = pke_enc(pk, m, r, k)

        sk_t = split_to_transactions(sk, masked=True)
        c_t = split_to_transactions(c)

        cocotb.start_soon(sample_inputs(dut, sk_t + c_t, mode))

        await RisingEdge(dut.clk)

        cocotb.start_soon(bram0_checks(dut, sk, c, k)),
        cocotb.start_soon(bram1_checks(dut, sk, c, k))

        dut.m_axis_tready.value = 1
        await RisingEdge(dut.clk)

        for i in range(0, len(m), 8):
            while dut.m_axis_tvalid.value != 1:
                await RisingEdge(dut.clk)

            # print(dut.m_axis_tdata.value.buff.hex())
            # print(m[i:i+8][::-1].hex())
            assert unmask_b(dut.m_axis_tdata.value) == m[i:i+8][::-1]

            dut.m_axis_tready.value = 0

            await wait_for_random_delay(dut.clk)

            dut.m_axis_tready.value = 1

            await RisingEdge(dut.clk)


@cocotb.test()
async def test_kyber_pke_dec2(dut):
    await test_kyber_pke_dec(dut, 2)

@cocotb.test()
async def test_kyber_pke_dec3(dut):
    await test_kyber_pke_dec(dut, 3)

@cocotb.test()
async def test_kyber_pke_dec4(dut):
    await test_kyber_pke_dec(dut, 4)


if __name__ == "__main__":
    run_tests('top', 'tests.kyber.pke_dec_tb', parameters={'SIMULATION': True})
