import numpy as np
import ctypes
import hashlib
from os import getcwd

cwd = getcwd().replace('/sim_build', '')

kyber512_lib = ctypes.cdll.LoadLibrary(f'{cwd}/libs/libpqcrystals_kyber512_ref.so')
kyber768_lib = ctypes.cdll.LoadLibrary(f'{cwd}/libs/libpqcrystals_kyber768_ref.so')
kyber1024_lib = ctypes.cdll.LoadLibrary(f'{cwd}/libs/libpqcrystals_kyber1024_ref.so')

Q = 3329

ZETAS = [1, 1729, 2580, 3289, 2642, 630, 1897, 848, 1062, 1919, 193, 797, 2786, 3260, 569, 1746, 296, 2447, 1339, 1476, 3046, 56, 2240, 1333, 1426, 2094, 535, 2882, 2393, 2879, 1974, 821, 289, 331, 3253, 1756, 1197, 2304, 2277, 2055, 650, 1977, 2513, 632, 2865, 33, 1320, 1915, 2319, 1435, 807, 452, 1438, 2868, 1534, 2402, 2647, 2617, 1481, 648, 2474, 3110, 1227, 910, 17, 2761, 583, 2649, 1637, 723, 2288, 1100, 1409, 2662, 3281, 233, 756, 2156, 3015, 3050, 1703, 1651, 2789, 1789, 1847, 952, 1461, 2687, 939, 2308, 2437, 2388, 733, 2337, 268, 641, 1584, 2298, 2037, 3220, 375, 2549, 2090, 1645, 1063, 319, 2773, 757, 2099, 561, 2466, 2594, 2804, 1092, 403, 1026, 1143, 2150, 2775, 886, 1722, 1212, 1874, 1029, 2110, 2935, 885, 2154]

class Poly(ctypes.Structure):
    _fields_ = [('coeffs', (256 * ctypes.c_int16))]

    def from_numpy(numpy):
        p = Poly()

        for i in range(256):
            p.coeffs[i] = numpy[i]

        return p

    def to_numpy(self):
        return np.array([barrett_reduce(self.coeffs[i]) for i in range(256)])

def barrett_reduce(x):
    return x % Q

def butterfly(x, y, zeta, mode):
    if mode == 0:
        return butterfly_ntt(x, y, zeta)
    elif mode == 1:
        return butterfly_intt(x, y, zeta)
    elif mode == 2:
        return butterfly_mul0(x, y, zeta)
    else:
        return butterfly_mul1(x, y, zeta)

def butterfly_ntt(x, y, zeta):
    t = barrett_reduce(y * zeta)

    return (barrett_reduce(x + t), barrett_reduce(x - t))

def butterfly_intt(x, y, zeta):
    x, y = (barrett_reduce(y + x), barrett_reduce((y - x) * zeta))

    if x & 0x1:
        x += Q
    if y & 0x1:
        y += Q

    return barrett_reduce(x >> 1), barrett_reduce(y >> 1)

def butterfly_mul0(x, y, zeta):
    return barrett_reduce(x + y), barrett_reduce(y * zeta)

def butterfly_mul0_poly(x, y):
    c, d = np.zeros_like(x), np.zeros_like(y)

    for i in range(0, 256, 4):
        c[i], d[i] = butterfly_mul0(x[i + 1], x[i], y[i])
        c[i + 1], d[i + 1] = butterfly_mul0(x[i + 3], x[i + 2], y[i + 2])
        c[i + 2], d[i + 2] = butterfly_mul0(y[i], y[i + 1], x[i + 1])
        c[i + 3], d[i + 3] = butterfly_mul0(y[i + 2], y[i + 3], x[i + 3])

    return c, d

def butterfly_mul1_poly(c, d):
    z = np.zeros_like(c)

    for i in range(0, 256, 4):
        zeta = ZETAS[64 + (i >> 2)]
        zeta_neg = -ZETAS[64 + (i >> 2)]

        _, z[i] = butterfly_mul1(-d[i], d[i + 2], zeta)
        _, z[i + 1] = butterfly_mul1(d[i] + d[i + 2], c[i], c[i + 2])
        _, z[i + 2] = butterfly_mul1(-d[i + 1], d[i + 3], zeta_neg)
        _, z[i + 3] = butterfly_mul1(d[i + 1] + d[i + 3], c[i + 1], c[i + 3])

    return z

def butterfly_mul1(x, y, zeta):
    return barrett_reduce(x), barrett_reduce(y * zeta - x)

def ntt(p: np.ndarray) -> np.ndarray:
    k = 1

    for i in reversed(range(1, 8)):
        j = 0

        for j in range(0, 256, (2 << i)):
            zeta = ZETAS[k]
            k += 1

            for l in range(j, j + (1 << i)):
                t = barrett_reduce(zeta * p[l + (1 << i)])
                p[l + (1 << i)] = barrett_reduce(p[l] - t)
                p[l] = barrett_reduce(p[l] + t)

    return p

def intt(p: np.ndarray) -> np.ndarray:
    k = 127

    for i in range(1, 8):
        j = 0

        while j < 256:
            zeta = ZETAS[k]
            k -= 1

            for l in range(j, j + (1 << i)):
                t = p[l]
                p[l] = barrett_reduce((t + p[l + (1 << i)]))
                p[l + (1 << i)] = barrett_reduce(p[l + (1 << i)] - t)
                p[l + (1 << i)] = barrett_reduce(zeta * p[l + (1 << i)])

                if p[l] & 1:
                    p[l] += Q
                if p[l + (1 << i)] & 1:
                    p[l + (1 << i)] += Q

                p[l] = barrett_reduce(p[l] >> 1)
                p[l + (1 << i)] = barrett_reduce(p[l + (1 << i)] >> 1)

            j = (l + 1) + (1 << i)

    return p

def poly_mul(x, y):
    x, y, z = Poly.from_numpy(x), Poly.from_numpy(y), Poly()

    kyber512_lib.pqcrystals_kyber512_ref_poly_ntt(ctypes.pointer(x))
    kyber512_lib.pqcrystals_kyber512_ref_poly_ntt(ctypes.pointer(y))

    kyber512_lib.pqcrystals_kyber512_ref_poly_basemul_montgomery(ctypes.pointer(z), ctypes.pointer(x), ctypes.pointer(y))
    kyber512_lib.pqcrystals_kyber512_ref_poly_invntt_tomont(ctypes.pointer(z))

    return z.to_numpy()

def poly_mul_debug(x, y):
    x, y = ntt(x), ntt(y)

    z = np.zeros_like(x)

    for i in range(0, 256, 2):
        zeta = ZETAS[64 + (i >> 2)] if i % 4 == 0 else -ZETAS[64 + (i >> 2)]
        c0, d0 = butterfly_mul0(x[i + 1], x[i], y[i])
        c1, d1 = butterfly_mul0(y[i], y[i + 1], x[i + 1])

        _, z[i] = butterfly_mul1(-d0, d1, zeta)
        _, z[i + 1] = butterfly_mul1(d0 + d1, c0, c1)

    return intt(z)

def sample_ntt(x, res):
    coeffs = (ctypes.c_int16 * 2)()
    n = kyber512_lib.pqcrystals_kyber512_ref_rej_uniform(coeffs, 2, x, 3)

    if n > 0:
        res.append(barrett_reduce(coeffs[0]))
    if n > 1 and len(res) < 256:
        res.append(barrett_reduce(coeffs[1]))

def sample_cbd2(x):
    coeffs = (ctypes.c_int16 * 256)()
    kyber512_lib.pqcrystals_kyber512_ref_poly_cbd_eta2(coeffs, x)

    return [barrett_reduce(int(x)) for x in coeffs]

def sample_cbd3(x):
    coeffs = (ctypes.c_int16 * 256)()
    kyber512_lib.pqcrystals_kyber512_ref_poly_cbd_eta1(coeffs, x)

    return [barrett_reduce(int(x)) for x in coeffs]

def compress(x, d):
    if d == 12: return x

    return (((x << d) + (Q >> 1)) // Q) & ((1 << d) - 1)

def decompress(x, d):
    if d == 12: return x

    return (x * Q + (1 << (d - 1))) >> d

def unpack_sk(sk, k):
    s = (Poly * k)()

    if k == 2:
        kyber512_lib.pqcrystals_kyber512_ref_polyvec_frombytes(s, sk)
    if k == 3:
        kyber768_lib.pqcrystals_kyber768_ref_polyvec_frombytes(s, sk)
    if k == 4:
        kyber1024_lib.pqcrystals_kyber1024_ref_polyvec_frombytes(s, sk)

    return s

def unpack_pk(pk, k):
    t = (Poly * k)()

    if k == 2:
        kyber512_lib.pqcrystals_kyber512_ref_polyvec_frombytes(t, pk)
    if k == 3:
        kyber768_lib.pqcrystals_kyber768_ref_polyvec_frombytes(t, pk)
    if k == 4:
        kyber1024_lib.pqcrystals_kyber1024_ref_polyvec_frombytes(t, pk)

    return t

def unpack_m(m):
    mu = np.zeros((256, ), dtype=np.int32)

    for i in range(256):
        if (m[i // 8] >> (i % 8)) & 1 == 1:
            mu[i] = 0x681

    return mu

def unpack_c(c, k):
    u = (Poly * k)()
    v = Poly()

    if k == 2:
        kyber512_lib.pqcrystals_kyber512_ref_polyvec_decompress(u, c)
        kyber512_lib.pqcrystals_kyber512_ref_poly_decompress(ctypes.pointer(v), c[2 * 320:])
    if k == 3:
        kyber768_lib.pqcrystals_kyber768_ref_polyvec_decompress(u, c)
        kyber768_lib.pqcrystals_kyber768_ref_poly_decompress(ctypes.pointer(v), c[3 * 320:])
    if k == 4:
        kyber1024_lib.pqcrystals_kyber1024_ref_polyvec_decompress(u, c)
        kyber1024_lib.pqcrystals_kyber1024_ref_poly_decompress(ctypes.pointer(v), c[4 * 352:])

    return (u, v)

def pke_key_pair(coins, k):
    pk = (ctypes.c_ubyte * (k * 384 + 32))()
    sk = (ctypes.c_ubyte * (k * 384))()

    if k == 2:
        kyber512_lib.pqcrystals_kyber512_ref_indcpa_keypair_derand(pk, sk, coins)
    if k == 3:
        kyber768_lib.pqcrystals_kyber768_ref_indcpa_keypair_derand(pk, sk, coins)
    if k == 4:
        kyber1024_lib.pqcrystals_kyber1024_ref_indcpa_keypair_derand(pk, sk, coins)

    pk = bytes(pk)
    sk = bytes(sk)

    return (pk, sk)

def pke_enc(pk, m, r, k):
    c = (ctypes.c_ubyte * (k * 352 + 160 if k == 4 else k * 320 + 128))()

    if k == 2:
        kyber512_lib.pqcrystals_kyber512_ref_indcpa_enc(c, m, pk, r)
    if k == 3:
        kyber768_lib.pqcrystals_kyber768_ref_indcpa_enc(c, m, pk, r)
    if k == 4:
        kyber1024_lib.pqcrystals_kyber1024_ref_indcpa_enc(c, m, pk, r)

    return bytes(c)

def kem_key_pair(coins, k):
    pk = (ctypes.c_ubyte * (k * 384 + 32))()
    sk = (ctypes.c_ubyte * (k * 384 + 32 + k * 384 + 32 + 32))()
    seed = (ctypes.c_ubyte * 32)()

    if k == 2:
        kyber512_lib.pqcrystals_kyber512_ref_keypair_derand(pk, sk, coins)
    if k == 3:
        kyber768_lib.pqcrystals_kyber768_ref_keypair_derand(pk, sk, coins)
    if k == 4:
        kyber1024_lib.pqcrystals_kyber1024_ref_keypair_derand(pk, sk, coins)

    pk = bytes(pk)
    sk = bytes(sk)

    return (pk, sk)

def expand_seed(seed, k):
    return hashlib.sha3_512(seed + k.to_bytes(1, 'little')).digest()

def sample_cbd(sigma, nonce, k):
    p = Poly()

    if k == 2:
        kyber512_lib.pqcrystals_kyber512_ref_poly_getnoise_eta1(ctypes.pointer(p), sigma, nonce)
    if k == 3:
        kyber768_lib.pqcrystals_kyber768_ref_poly_getnoise_eta1(ctypes.pointer(p), sigma, nonce)
    if k == 4:
        kyber1024_lib.pqcrystals_kyber1024_ref_poly_getnoise_eta1(ctypes.pointer(p), sigma, nonce)

    return p

def expand_a(rho, k):
    a = ((Poly * k) * k)()

    if k == 2:
        kyber512_lib.pqcrystals_kyber512_ref_gen_matrix(a, rho, 0)
    if k == 3:
        kyber768_lib.pqcrystals_kyber768_ref_gen_matrix(a, rho, 0)
    if k == 4:
        kyber1024_lib.pqcrystals_kyber1024_ref_gen_matrix(a, rho, 0)

    return a

def h_pk(pk):
    return hashlib.sha3_256(pk).digest()

def k_r(m, pk):
    h = hashlib.sha3_512(m + h_pk(pk)).digest()

    return h[:32], h[32:]

def j(z, c):
    return hashlib.shake_256(z + c).digest(32)

def quadrant(x):
    if x <= 832: return 0
    if x <= 1664: return 1
    if x <= 2496: return 2
    return 3

def compress_masked(x):
    i, j = quadrant(x[0]), quadrant(x[1])

    if (i + j) % 4 == 1:
        return 1
    if (i + j) % 4 == 3:
        return 0

    delta = ((i + 1) * Q >> 2) - x[0], x[1] - (j * Q >> 2)

    if delta[1] > delta[0]:
        if (i + j) % 4 == 0:
            return 1
        else:
            return 0
    else:
        if (i + j) % 4 == 2:
            return 1
        else:
            return 0
