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

async def data_checks(dut, sk, c, m, K, r, k):
    await check_data(dut, dut.tr_vld, sk[-96:-64] + b'\x00' * 32 + sk[-64:])

    await check_data(dut, dut.mu_vld, sk[-96:-64] + b'\x00' * 32 + sk[-64:] + m)

    await check_data(dut, dut.seeds_vld, sk[-96:-64] + b'\x00' * 32 + sk[-64:-32] + K + r + b'\x00' * 64 + j(sk[-32:], c))

    print('data finished')

async def bram0_checks(dut, sk, c, m, K, r, k):
    poly_offset = 0
    u, v = unpack_c(c, k)

    for i in range(k):
        await check_memory(dut, dut.bram0, u[i].to_numpy(), 8, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset)
        poly_offset = (poly_offset + 1) % 16

    await check_memory(dut, dut.bram0, v.to_numpy(), 8, vld_sig=dut.bram0_polys_vld, poly_offset=poly_offset)
    poly_offset = (poly_offset + 1) % 16


    a = expand_a(sk[-96:-64], k)

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

async def bram1_checks(dut, sk, c, m, K, r, k):
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
        # await check_memory(dut, dut.bram1, c, 8, poly_offset=5 * k)
        await check_memory(dut, dut.bram1, d, 8, poly_offset=2 * k, masked=True)

        w = (w + z) % Q

        await wait_for_vld_addr(2 * k)
        await check_memory(dut, dut.bram1, w, 8, poly_offset=2 * k, masked=True)

    await wait_for_vld_addr(2 * k)
    await check_memory(dut, dut.bram1, intt(w), 8, poly_offset=2 * k, masked=True)

    t = unpack_pk(sk[384 * k:], k)
    a = expand_a(sk[-96:-64], k)

    while dut.seeds_vld.value != 1:
        await RisingEdge(dut.clk)

    for i in range(0, len(m), 8):
        dut.bram1.debug_addr.value = (4 * k * 256 + i) // 8
        await Timer(10, units='ns')
        assert compress(((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) & 0xfff, 1) == m[i // 8] & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 12) & 0xfff, 1) == (m[i // 8] >> 1) & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 24) & 0xfff, 1) == (m[i // 8] >> 2) & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 36) & 0xfff, 1) == (m[i // 8] >> 3) & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 48) & 0xfff, 1) == (m[i // 8] >> 4) & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 60) & 0xfff, 1) == (m[i // 8] >> 5) & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 72) & 0xfff, 1) == (m[i // 8] >> 6) & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 84) & 0xfff, 1) == (m[i // 8] >> 7) & 0x1

    r_ntt = []
    for i in range(k):
        r_ntt.append(ntt(sample_cbd(r, i, k).to_numpy()))
        await wait_for_vld_addr(2 * k + 1 + i)
        await check_memory(dut, dut.bram1, r_ntt[-1], 8, poly_offset=2 * k + 1 + i, masked=True)

    for i in range(k):
        await check_memory(dut, dut.bram1, t[i].to_numpy(), 8, poly_offset=k + i)

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

    for i in range(0, len(m), 8):
        dut.bram1.debug_addr.value = (4 * k * 256 + i) // 8
        await Timer(10, units='ns')
        assert compress(((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) & 0xfff, 1) == m[i // 8] & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 12) & 0xfff, 1) == (m[i // 8] >> 1) & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 24) & 0xfff, 1) == (m[i // 8] >> 2) & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 36) & 0xfff, 1) == (m[i // 8] >> 3) & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 48) & 0xfff, 1) == (m[i // 8] >> 4) & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 60) & 0xfff, 1) == (m[i // 8] >> 5) & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 72) & 0xfff, 1) == (m[i // 8] >> 6) & 0x1
        assert compress((((dut.bram1.debug_data.value.integer >> 96) + dut.bram1.debug_data.value.integer) >> 84) & 0xfff, 1) == (m[i // 8] >> 7) & 0x1

    print('bram1 finished')


async def test_kyber_kem_dec(dut, k):
    await initialize_component(dut)

    cocotb.start_soon(send_randomness(dut.sec_conversion_random, dut.clk, 776, dut.sec_conversion_random_mode, Q))
    cocotb.start_soon(send_randomness(dut.other_random, dut.clk, 25))

    for _ in range(TEST_CASES):
        mode = 0b00000100000 if k == 2 else 0b01000100000 if k == 3 else 0b10000100000

        coins = urandom(64)
        pk, sk = kem_key_pair(coins, k)
        m = urandom(32)
        K, r = k_r(m, pk)
        c = pke_enc(pk, m, r, k)

        valid = True

        if random.random() < 0.5:
            valid = False

            if random.random() < 0.5:
                print('changing c')
                i = random.randint(0, len(c) - 1)
                c = c[:i] + urandom(1) + c[i + 1:]
            else:
                print('changing sk')
                i = random.randint(0, len(sk) - 1)
                sk = sk[:i] + urandom(1) + sk[i + 1:]

        sk_t = split_to_transactions(sk[:384 * k], masked=True) + split_to_transactions(sk[384 * k:-32]) + split_to_transactions(sk[-32:], masked=True)
        c_t = split_to_transactions(c)

        cocotb.start_soon(sample_inputs(dut, sk_t + c_t, mode))

        await RisingEdge(dut.clk)

        if not valid:
            K = j(sk[-32:], c)
        else:
            # continual tests only for valid inputs
            cocotb.start_soon(bram0_checks(dut, sk, c, m, K, r, k)),
            cocotb.start_soon(bram1_checks(dut, sk, c, m, K, r, k)),
            cocotb.start_soon(data_checks(dut, sk, c, m, K, r, k))

        dut.m_axis_tready.value = 1
        await RisingEdge(dut.clk)

        for i in range(0, len(K), 8):
            while dut.m_axis_tvalid.value != 1:
                await RisingEdge(dut.clk)

            # print(dut.m_axis_tdata.value.buff.hex())
            # print(K[i:i+8][::-1].hex())
            assert unmask_b(dut.m_axis_tdata.value) == K[i:i+8][::-1]

            dut.m_axis_tready.value = 0

            await wait_for_random_delay(dut.clk)

            dut.m_axis_tready.value = 1

            await RisingEdge(dut.clk)


@cocotb.test()
async def test_kyber_kem_dec2(dut):
    await test_kyber_kem_dec(dut, 2)

@cocotb.test()
async def test_kyber_kem_dec3(dut):
    await test_kyber_kem_dec(dut, 3)

@cocotb.test()
async def test_kyber_kem_dec4(dut):
    await test_kyber_kem_dec(dut, 4)

if __name__ == "__main__":
    run_tests('top', 'tests.kyber.kem_dec_tb', parameters={'SIMULATION': True})
