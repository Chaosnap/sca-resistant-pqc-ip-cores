import random

from functools import reduce
from cocotb.triggers import RisingEdge

from tests.kyber.kyber import *
from tests.utils import *

TEST_CASES = 1000

def unmask_boolean(shares):
    return shares[0] ^ shares[1]

def generate_tests():
    inputs = [[(random.randint(0, Q - 1), random.randint(0, Q - 1)) for _ in range(8)] for _ in range(TEST_CASES)]
    outputs = [[compress((x[i][0] + x[i][1]) % Q, 1) for i in range(8)] for x in inputs]

    def inputs_gen():
        for x in inputs:
            yield serialize_coeffs(x, masked=True)

    def outputs_gen():
        for z in outputs:
            yield reduce(lambda acc, x: acc + (int(x[1]) << x[0]), enumerate(z), 0)

    return inputs_gen, outputs_gen

@cocotb.test()
async def test_sec_decoder(dut):
    inputs_gen, outputs_gen = generate_tests()

    await test_component(dut, inputs_gen, outputs_gen, output_convert_f=unmask_boolean, random_bits=776)

if __name__ == '__main__':
    run_tests('sec_decoder_top', 'tests.masking.sec_decoder_tb')
