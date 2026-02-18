import random

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from tests.utils import *
from tests.dilithium.dilithium import key_pair, sign
from tests.kyber.kyber import pke_key_pair, pke_enc, kem_key_pair, k_r

UART_CYCLES_PER_BIT = 6

def random_bytes(count):
    return random.getrandbits(count << 3).to_bytes(count)

def transactions_to_data(transactions):
    data = b''

    for tx in transactions:
        data += tx[1].to_bytes(8, 'little')
        data += tx[0].to_bytes(8, 'little')

    return data

async def send_byte(dut, b):
    dut.uart_rx.value = 0

    await ClockCycles(dut.clk, UART_CYCLES_PER_BIT)

    for _ in range(8):
        dut.uart_rx.value = b & 0x1
        b >>= 1

        await ClockCycles(dut.clk, UART_CYCLES_PER_BIT)

    dut.uart_rx.value = 1

    await ClockCycles(dut.clk, UART_CYCLES_PER_BIT)

async def send_data(dut, data):
    for i, b in enumerate(data):
        await send_byte(dut, b)
        # print(f'sent byte {i+1}/{len(data)}: {hex(b)}')

async def read_byte(dut):
    b = 0

    while dut.uart_tx.value == 1:
        await RisingEdge(dut.clk)

    await ClockCycles(dut.clk, UART_CYCLES_PER_BIT)

    for _ in range(8):
        b += (dut.uart_tx.value << 8)
        b >>= 1

        await ClockCycles(dut.clk, UART_CYCLES_PER_BIT)

    return b

async def read_data(dut, count):
    data = []

    for i in range(count):
        data.append(await read_byte(dut))
        # print(f'read byte {i+1}/{count}: {hex(data[-1])}')

    return bytes(data)

async def test_component(dut, mode, i, o):
    dut.uart_rx.value = 1

    await initialize_component(dut)

    await send_byte(dut, 1)
    await send_byte(dut, mode)
    await send_data(dut, i)

    for i in range(0, len(o), 8):
        shares = (await read_data(dut, 8), await read_data(dut, 8))
        unmasked = (int.from_bytes(shares[0]) ^ int.from_bytes(shares[1])).to_bytes(8)

        # print(i)
        # print(o[i:i+8].hex())
        # print(unmasked.hex())
        assert o[i:i+8] == unmasked

@cocotb.test()
async def test_key_gen(dut):
    for k in (2, 3, 5):
        pk, sk, seed = key_pair(k)

        seed = transactions_to_data(split_to_transactions(seed))

        if k == 5:
            k -= 1

        await test_component(dut, ((k - 2) << 4) + 0x07, seed, pk + sk)

@cocotb.test()
async def test_sign(dut):
    for k in (2, 3, 5):
        pk, sk, _ = key_pair(k)
        ctx = random_bytes(1)
        msg = random_bytes(28)
        rnd = b'\x00' * 32 # urandom(32)

        sig = sign(sk, msg, ctx, k)

        msg = b'\x00' + len(ctx).to_bytes(1, 'little') + ctx + msg
        # add padding to message
        msg = msg + b'\x1f'

        # make sure it is aligned to 8B
        while len(msg) % 8 != 0:
            msg += b'\x00'

        sk = transactions_to_data(split_to_transactions(sk[:32]) + split_to_transactions(sk[32:64], masked=True) + split_to_transactions(sk[64:128]) + split_to_transactions(sk[128:], masked=True))
        rnd = transactions_to_data(split_to_transactions(rnd, masked=True))
        msg = transactions_to_data(split_to_transactions(msg))

        if k == 5:
            k -= 1

        await test_component(dut, ((k - 2) << 4) + 0x08, sk + rnd + msg, sig)

@cocotb.test()
async def test_verify(dut):
    for k in (2, 3, 5):
        pk, sk, _ = key_pair(k)
        ctx = random_bytes(1)
        msg = random_bytes(28)
        rnd = b'\x00' * 32 # urandom(32)

        sig = sign(sk, msg, ctx, k)

        msg = b'\x00' + len(ctx).to_bytes(1, 'little') + ctx + msg
        # add padding to message
        msg = msg + b'\x1f'

        # make sure it is aligned to 8B
        while len(msg) % 8 != 0:
            msg += b'\x00'

        pk = transactions_to_data(split_to_transactions(pk))
        sig = transactions_to_data(split_to_transactions(sig))
        msg = transactions_to_data(split_to_transactions(msg))

        if k == 5:
            k -= 1

        await test_component(dut, ((k - 2) << 4) + 0x09, pk + sig + msg, b'\x01' + 7 * b'\x00')

@cocotb.test()
async def test_kem_key_gen(dut):
    for k in (2, 3, 4):
        coins = random_bytes(64)
        pk, sk = kem_key_pair(coins, k)

        coins = transactions_to_data(split_to_transactions(coins, masked=True))

        await test_component(dut, ((k - 2) << 4) + 0x04, coins, pk + sk)

@cocotb.test()
async def test_kem_enc(dut):
    for k in (2, 3, 4):
        coins = random_bytes(64)
        pk, _ = pke_key_pair(coins, k)
        m = random_bytes(32)
        K, r = k_r(m, pk)
        c = pke_enc(pk, m, r, k)

        pk = transactions_to_data(split_to_transactions(pk))
        m = transactions_to_data(split_to_transactions(m, masked=True))

        await test_component(dut, ((k - 2) << 4) + 0x05, pk + m, c + K)

@cocotb.test()
async def test_kem_dec(dut):
    for k in (2, 3, 4):
        coins = random_bytes(64)
        pk, sk = kem_key_pair(coins, k)
        m = random_bytes(32)
        K, r = k_r(m, pk)
        c = pke_enc(pk, m, r, k)

        sk = transactions_to_data(split_to_transactions(sk[:384 * k], masked=True) + split_to_transactions(sk[384 * k:-32]) + split_to_transactions(sk[-32:], masked=True))
        c = transactions_to_data(split_to_transactions(c))

        await test_component(dut, ((k - 2) << 4) + 0x06, sk + c, K)

if __name__ == "__main__":
    run_tests('wrapper', 'tests.wrapper_tb', parameters={'UART_CYCLES_PER_BIT': UART_CYCLES_PER_BIT})
