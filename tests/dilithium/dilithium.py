import numpy as np
import ctypes
import hashlib
from os import getcwd

cwd = getcwd().replace('/sim_build', '')

dilithium2_lib = ctypes.cdll.LoadLibrary(f'{cwd}/libs/libpqcrystals_dilithium2_ref.so')
dilithium3_lib = ctypes.cdll.LoadLibrary(f'{cwd}/libs/libpqcrystals_dilithium3_ref.so')
dilithium5_lib = ctypes.cdll.LoadLibrary(f'{cwd}/libs/libpqcrystals_dilithium5_ref.so')

Q = 8380417
ZETAS = [0, 4808194, 3765607, 3761513, 5178923, 5496691, 5234739, 5178987, 7778734, 3542485, 2682288, 2129892, 3764867, 7375178, 557458, 7159240, 5010068, 4317364, 2663378, 6705802, 4855975, 7946292, 676590, 7044481, 5152541, 1714295, 2453983, 1460718, 7737789, 4795319, 2815639, 2283733, 3602218, 3182878, 2740543, 4793971, 5269599, 2101410, 3704823, 1159875, 394148, 928749, 1095468, 4874037, 2071829, 4361428, 3241972, 2156050, 3415069, 1759347, 7562881, 4805951, 3756790, 6444618, 6663429, 4430364, 5483103, 3192354, 556856, 3870317, 2917338, 1853806, 3345963, 1858416, 3073009, 1277625, 5744944, 3852015, 4183372, 5157610, 5258977, 8106357, 2508980, 2028118, 1937570, 4564692, 2811291, 5396636, 7270901, 4158088, 1528066, 482649, 1148858, 5418153, 7814814, 169688, 2462444, 5046034, 4213992, 4892034, 1987814, 5183169, 1736313, 235407, 5130263, 3258457, 5801164, 1787943, 5989328, 6125690, 3482206, 4197502, 7080401, 6018354, 7062739, 2461387, 3035980, 621164, 3901472, 7153756, 2925816, 3374250, 1356448, 5604662, 2683270, 5601629, 4912752, 2312838, 7727142, 7921254, 348812, 8052569, 1011223, 6026202, 4561790, 6458164, 6143691, 1744507, 1753, 6444997, 5720892, 6924527, 2660408, 6600190, 8321269, 2772600, 1182243, 87208, 636927, 4415111, 4423672, 6084020, 5095502, 4663471, 8352605, 822541, 1009365, 5926272, 6400920, 1596822, 4423473, 4620952, 6695264, 4969849, 2678278, 4611469, 4829411, 635956, 8129971, 5925040, 4234153, 6607829, 2192938, 6653329, 2387513, 4768667, 8111961, 5199961, 3747250, 2296099, 1239911, 4541938, 3195676, 2642980, 1254190, 8368000, 2998219, 141835, 8291116, 2513018, 7025525, 613238, 7070156, 6161950, 7921677, 6458423, 4040196, 4908348, 2039144, 6500539, 7561656, 6201452, 6757063, 2105286, 6006015, 6346610, 586241, 7200804, 527981, 5637006, 6903432, 1994046, 2491325, 6987258, 507927, 7192532, 7655613, 6545891, 5346675, 8041997, 2647994, 3009748, 5767564, 4148469, 749577, 4357667, 3980599, 2569011, 6764887, 1723229, 1665318, 2028038, 1163598, 5011144, 3994671, 8368538, 7009900, 3020393, 3363542, 214880, 545376, 7609976, 3105558, 7277073, 508145, 7826699, 860144, 3430436, 140244, 6866265, 6195333, 3123762, 2358373, 6187330, 5365997, 6663603, 2926054, 7987710, 8077412, 3531229, 4405932, 4606686, 1900052, 7598542, 1054478, 7648983]

def k_l(sec_level):
    if sec_level == 2:
        return (4, 4)
    if sec_level == 3:
        return (6, 5)

    return (8, 7)

class Poly(ctypes.Structure):
    _fields_ = [('coeffs', (256 * ctypes.c_int32))]

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
    else:
        return butterfly_mul(x, y, zeta)

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

def butterfly_mul(x, y, zeta):
    return barrett_reduce(x + y), barrett_reduce(y * zeta)

def ntt(p: np.ndarray) -> np.ndarray:
    k = 1

    for i in reversed(range(0, 8)):
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
    k = 255

    for i in range(0, 8):
        j = 0

        while j < 256:
            zeta = -ZETAS[k]
            k -= 1

            for l in range(j, j + (1 << i)):
                t = p[l]
                p[l] = barrett_reduce((t + p[l + (1 << i)]))
                # IMPORTANT: changes order what is subtracted
                p[l + (1 << i)] = barrett_reduce(t - p[l + (1 << i)])
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

    dilithium2_lib.pqcrystals_dilithium2_ref_poly_ntt(ctypes.pointer(x))
    dilithium2_lib.pqcrystals_dilithium2_ref_poly_ntt(ctypes.pointer(y))

    dilithium2_lib.pqcrystals_dilithium2_ref_poly_pointwise_montgomery(ctypes.pointer(z), ctypes.pointer(x), ctypes.pointer(y))
    dilithium2_lib.pqcrystals_dilithium2_ref_poly_invntt_tomont(ctypes.pointer(z))

    return z.to_numpy()

def poly_mul_debug(x, y):
    x, y = ntt(x), ntt(y)

    z = np.zeros_like(x)

    for i in range(0, 256):
        _, z[i] = butterfly_mul(x[i], x[i], y[i])

    return intt(z)

def poly_mul_orig(x, y):
    z = np.polymul(list(reversed(x)), list(reversed(y))) % Q

    _, rem = np.polydiv(z, [1] + [0] * 255 + [1])

    return list(map(barrett_reduce, reversed(rem.astype(int))))

def sample_ntt(x, res):
    coeffs = (ctypes.c_int32 * 2)()
    n = dilithium2_lib.pqcrystals_dilithium2_ref_rej_uniform(coeffs, 2, x, 6)

    if n > 0:
        res.append(barrett_reduce(coeffs[0]))
    if n > 1 and len(res) < 256:
        res.append(barrett_reduce(coeffs[1]))

def sample_bounded2(x, res):
    x = int.from_bytes(x)

    if x & 0xf < 5:
        res.append((2 - (x & 0xf)) % Q)

    x >>= 4
    if x & 0xf < 5 and len(res) < 256:
        res.append((2 - (x & 0xf)) % Q)

def sample_bounded4(x, res):
    coeffs = (ctypes.c_int32 * 2)()
    n = dilithium3_lib.pqcrystals_dilithium3_ref_rej_eta(coeffs, 2, x, 1)

    if n > 0:
        res.append(barrett_reduce(coeffs[0]))
    if n > 1 and len(res) < 256:
        res.append(barrett_reduce(coeffs[1]))

def decompose(x, version):
    x0 = ctypes.c_int32()

    if version == 0:
        x = dilithium2_lib.pqcrystals_dilithium2_ref_decompose(ctypes.pointer(x0), x)
    if version == 1:
        x = dilithium3_lib.pqcrystals_dilithium3_ref_decompose(ctypes.pointer(x0), x)

    return (x0.value, x)

def power2round(x):
    x0 = ctypes.c_int32()

    x = dilithium2_lib.pqcrystals_dilithium2_ref_power2round(ctypes.pointer(x0), x)

    return (x0.value, x)

def key_pair(sec_level):
    k, l = k_l(sec_level)

    eta_bytes = 128 if sec_level == 3 else 96

    pk = (ctypes.c_ubyte * (32 + k * 320))()
    sk = (ctypes.c_ubyte * (2 * 32 + 64 + l * eta_bytes + k * eta_bytes + k * 416))()
    seed = (ctypes.c_ubyte * 32)()

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_keypair(pk, sk, seed)
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_keypair(pk, sk, seed)
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_keypair(pk, sk, seed)

    pk = bytes(pk)
    sk = bytes(sk)
    seed = bytes(seed)

    return (pk, sk, seed)

def sign(sk, msg, ctx, sec_level):
    k, l = k_l(sec_level)

    c_len = 32 if sec_level == 2 else 48 if sec_level == 3 else 64
    z_packed = 576 if sec_level == 2 else 640
    omega = 80 if sec_level == 2 else 55 if sec_level == 3 else 75

    sig = (ctypes.c_ubyte * (c_len + l * z_packed + omega + k))()
    sig_len = ctypes.pointer(ctypes.c_int())

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_signature(sig, sig_len, msg, len(msg), ctx, len(ctx), sk)
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_signature(sig, sig_len, msg, len(msg), ctx, len(ctx), sk)
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_signature(sig, sig_len, msg, len(msg), ctx, len(ctx), sk)

    sig = bytes(sig)

    # make sure it is aligned to 64bits transactions
    while len(sig) % 8 != 0:
        sig += b'\x00'

    return sig

def unpack_sk(sk, sec_level):
    k, l = k_l(sec_level)

    rho = (ctypes.c_ubyte * 32)()
    tr = (ctypes.c_ubyte * 64)()
    key = (ctypes.c_ubyte * 32)()

    t0 = (Poly * k)()
    s1 = (Poly * l)()
    s2 = (Poly * k)()

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_unpack_sk(rho, tr, key, t0, s1, s2, sk)
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_unpack_sk(rho, tr, key, t0, s1, s2, sk)
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_unpack_sk(rho, tr, key, t0, s1, s2, sk)

    return (t0, s1, s2)

def unpack_pk(pk, sec_level):
    k, l = k_l(sec_level)

    rho = (ctypes.c_ubyte * 32)()

    t1 = (Poly * k)()

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_unpack_pk(rho, t1, pk)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_shiftl(t1)
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_unpack_pk(rho, t1, pk)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_shiftl(t1)
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_unpack_pk(rho, t1, pk)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_shiftl(t1)

    return t1

def unpack_sig(sig, sec_level):
    k, l = k_l(sec_level)

    c_len = 32 if sec_level == 2 else 48 if sec_level == 3 else 64
    c = (ctypes.c_ubyte * c_len)()

    z = (Poly * l)()
    h = (Poly * k)()

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_unpack_sig(c, z, h, sig)
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_unpack_sig(c, z, h, sig)
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_unpack_sig(c, z, h, sig)

    return (z, h)

def mu(sk, msg):
    return hashlib.shake_256(sk[64:128] + msg).digest(64)

def rho_prime(sk, msg, rnd):
    return hashlib.shake_256(sk[32:64] + rnd + mu(sk, msg)).digest(64)

def expand_seed(seed, sec_level):
    k, l = k_l(sec_level)
    return hashlib.shake_256(seed + k.to_bytes(1, 'little') + l.to_bytes(1, 'little')).digest(128)

def expand_a(rho, sec_level):
    k, l = k_l(sec_level)

    a = ((Poly * l) * k)()

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_polyvec_matrix_expand(a, rho)
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_polyvec_matrix_expand(a, rho)
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_polyvec_matrix_expand(a, rho)

    return a

def expand_s(rho_prime, sec_level):
    k, l = k_l(sec_level)

    s1 = (Poly * l)()
    s2 = (Poly * k)()

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_polyvecl_uniform_eta(s1, rho_prime, 0)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_uniform_eta(s2, rho_prime, l)
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_polyvecl_uniform_eta(s1, rho_prime, 0)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_uniform_eta(s2, rho_prime, l)
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_polyvecl_uniform_eta(s1, rho_prime, 0)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_uniform_eta(s2, rho_prime, l)

    return (s1, s2)

def expand_mask(rho_prime, nonce, sec_level):
    _, l = k_l(sec_level)

    y = (Poly * l)()

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_polyvecl_uniform_gamma1(y, rho_prime, nonce)
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_polyvecl_uniform_gamma1(y, rho_prime, nonce)
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_polyvecl_uniform_gamma1(y, rho_prime, nonce)

    return y

def compute_w_t(a, y, sec_level):
    k, _ = k_l(sec_level)

    w = (Poly * k)()

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_polyvecl_ntt(y)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyvec_matrix_pointwise_montgomery(w, a, y)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_reduce(w)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_invntt_tomont(w)
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_polyvecl_ntt(y)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyvec_matrix_pointwise_montgomery(w, a, y)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_reduce(w)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_invntt_tomont(w)
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_polyvecl_ntt(y)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyvec_matrix_pointwise_montgomery(w, a, y)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_reduce(w)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_invntt_tomont(w)

    return w

def compute_c(mu, w, sec_level):
    k, _ = k_l(sec_level)

    sig = (ctypes.c_ubyte * 1024)()
    w0 = (Poly * k)()

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_caddq(w)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_decompose(w, w0, w)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_pack_w1(sig, w)

        return hashlib.shake_256(mu + bytes(sig)[:768]).digest(32), w0
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_caddq(w)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_decompose(w, w0, w)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_pack_w1(sig, w)

        return hashlib.shake_256(mu + bytes(sig)[:768]).digest(48), w0
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_caddq(w)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_decompose(w, w0, w)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_pack_w1(sig, w)

        return hashlib.shake_256(mu + bytes(sig)).digest(64), w0

def sample_in_ball(rho, sec_level):
    hash = hashlib.shake_256(rho).digest(1000)

    if sec_level == 2:
        tau = 39
    if sec_level == 3:
        tau = 49
    if sec_level == 5:
        tau = 60

    i = hash[:8]
    offset = 8
    signs = int.from_bytes(i, 'little')
    o = [0 for _ in range(256)]
    for j in range(256 - tau, 256):
        x = hash[offset:offset+1]
        offset += 1
        i += x

        while int.from_bytes(x, 'little') > j:
            x = hash[offset:offset+1]
            offset += 1
            i += x

        o[j] = o[int.from_bytes(x, 'little')]
        o[int.from_bytes(x, 'little')] = -1 % Q if ((signs >> (j + tau - 256)) & 0x1) else 1

    return (i, np.array(o))


def compress(x, d):
    return (d - x) % Q

def compute_z(c, y, s1, sec_level):
    _, l = k_l(sec_level)

    z = (Poly * l)()
    _, cp = sample_in_ball(c, sec_level)
    cp = ctypes.pointer(Poly.from_numpy(cp))

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_polyvecl_ntt(s1)
        dilithium2_lib.pqcrystals_dilithium2_ref_poly_ntt(cp)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyvecl_pointwise_poly_montgomery(z, cp, s1)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyvecl_invntt_tomont(z)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyvecl_add(z, z, y)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyvecl_reduce(z)
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_polyvecl_ntt(s1)
        dilithium3_lib.pqcrystals_dilithium3_ref_poly_ntt(cp)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyvecl_pointwise_poly_montgomery(z, cp, s1)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyvecl_invntt_tomont(z)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyvecl_add(z, z, y)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyvecl_reduce(z)
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_polyvecl_ntt(s1)
        dilithium5_lib.pqcrystals_dilithium5_ref_poly_ntt(cp)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyvecl_pointwise_poly_montgomery(z, cp, s1)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyvecl_invntt_tomont(z)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyvecl_add(z, z, y)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyvecl_reduce(z)

    return z

def compute_r0(c, w0, s2, sec_level):
    k, _ = k_l(sec_level)

    h = (Poly * k)()
    _, cp = sample_in_ball(c, sec_level)
    cp = ctypes.pointer(Poly.from_numpy(cp))

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_ntt(s2)
        dilithium2_lib.pqcrystals_dilithium2_ref_poly_ntt(cp)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_pointwise_poly_montgomery(h, cp, s2)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_invntt_tomont(h)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_sub(w0, w0, h)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_reduce(w0)
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_ntt(s2)
        dilithium3_lib.pqcrystals_dilithium3_ref_poly_ntt(cp)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_pointwise_poly_montgomery(h, cp, s2)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_invntt_tomont(h)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_sub(w0, w0, h)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_reduce(w0)
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_ntt(s2)
        dilithium5_lib.pqcrystals_dilithium5_ref_poly_ntt(cp)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_pointwise_poly_montgomery(h, cp, s2)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_invntt_tomont(h)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_sub(w0, w0, h)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_reduce(w0)

    return w0

def compute_ct0(c, t0, sec_level):
    k, _ = k_l(sec_level)

    h = (Poly * k)()
    _, cp = sample_in_ball(c, sec_level)
    cp = ctypes.pointer(Poly.from_numpy(cp))

    if sec_level == 2:
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_ntt(t0)
        dilithium2_lib.pqcrystals_dilithium2_ref_poly_ntt(cp)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_pointwise_poly_montgomery(h, cp, t0)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_invntt_tomont(h)
        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_reduce(h)
    if sec_level == 3:
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_ntt(t0)
        dilithium3_lib.pqcrystals_dilithium3_ref_poly_ntt(cp)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_pointwise_poly_montgomery(h, cp, t0)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_invntt_tomont(h)
        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_reduce(h)
    if sec_level == 5:
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_ntt(t0)
        dilithium5_lib.pqcrystals_dilithium5_ref_poly_ntt(cp)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_pointwise_poly_montgomery(h, cp, t0)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_invntt_tomont(h)
        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_reduce(h)

    return h

def make_hint(_w0, _w1, sec_level, h_ = None):
    k, _ = k_l(sec_level)
    w0 = (Poly * k)()
    w1 = (Poly * k)()
    h = (Poly * k)()

    if h_ == None:
        for i in range(k):
            w0[i] = Poly.from_numpy(_w0[i])
            w1[i] = Poly.from_numpy(_w1[i])
    else:
        w0 = _w0
        w1 = _w1

    if sec_level == 2:
        if h_ != None:
            dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_add(w0, w0, h_)

        dilithium2_lib.pqcrystals_dilithium2_ref_polyveck_make_hint(h, w0, w1)
    if sec_level == 3:
        if h_ != None:
            dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_add(w0, w0, h_)

        dilithium3_lib.pqcrystals_dilithium3_ref_polyveck_make_hint(h, w0, w1)
    if sec_level == 5:
        if h_ != None:
            dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_add(w0, w0, h_)

        dilithium5_lib.pqcrystals_dilithium5_ref_polyveck_make_hint(h, w0, w1)

    out = []
    counts = []
    count = 0

    omega = 80 if sec_level == 2 else 55 if sec_level == 3 else 75

    for i in range(k):
        for j in range(256):
            if h[i].coeffs[j] != 0:
                count += 1
                if count == omega + 1:
                    break
                out.append(j)
        counts.append(count)
        if count == omega + 1:
            break


    for j in range(len(out), omega):
        out.append(0)

    out += counts

    while len(out) % 8 != 0:
        out.append(0)

    return out, count <= omega

def use_hint(hints, valid, w0, w1, sec_level):
    k, _ = k_l(sec_level)

    w1_out = np.array(w1)
    if not valid:
        return w1_out

    for i in range(k):
        for j in range(256):
            if w0[i][j] < 0:
                w1[i][j] += 0x8000


    mod = 0x2c if sec_level == 2 else 0x10
    omega = 80 if sec_level == 2 else 55 if sec_level == 3 else 75

    index = 0

    for i in range(k):
        if hints[omega + i] < index or hints[omega + i] > omega: break

        while index < hints[omega + i]:
            if w1[i][hints[index]] > 0x4000:
                w1_out[i][hints[index]] = (w1_out[i][hints[index]] - 1) % mod
            else:
                w1_out[i][hints[index]] = (w1_out[i][hints[index]] + 1) % mod
            index += 1


    return w1_out



def bound_check_z(z, sec_level):
    bound = (1 << 17) - 78 if sec_level == 2 else (1 << 19) - 196 if sec_level == 3 else (1 << 19) - 120

    p = ctypes.pointer(Poly.from_numpy(z))

    dilithium2_lib.pqcrystals_dilithium2_ref_poly_reduce(p)
    return True if dilithium2_lib.pqcrystals_dilithium2_ref_poly_chknorm(p, bound) == 0 else False

def bound_check_r0(r0, sec_level):
    bound = (Q - 1) // 88 - 78 if sec_level == 2 else (Q - 1) // 32 - 196 if sec_level == 3 else (Q - 1) // 32 - 120

    p = ctypes.pointer(Poly.from_numpy(r0))

    dilithium2_lib.pqcrystals_dilithium2_ref_poly_reduce(p)
    return True if dilithium2_lib.pqcrystals_dilithium2_ref_poly_chknorm(p, bound) == 0 else False

def bound_check_ct0(ct0, sec_level):
    bound = (Q - 1) // 88 if sec_level == 2 else (Q - 1) // 32 if sec_level == 3 else (Q - 1) // 32

    p = ctypes.pointer(Poly.from_numpy(ct0))

    dilithium2_lib.pqcrystals_dilithium2_ref_poly_reduce(p)
    return True if dilithium2_lib.pqcrystals_dilithium2_ref_poly_chknorm(p, bound) == 0 else False

def pack_z(z, sec_level):
    _, l = k_l(sec_level)
    z_bytes = 576 if sec_level == 2 else 640

    full_sig = b''

    for i in range(l):
        sig = (ctypes.c_ubyte * z_bytes)()

        if sec_level == 2:
            dilithium2_lib.pqcrystals_dilithium2_ref_polyz_pack(sig, ctypes.pointer(z[i]))
        if sec_level == 3:
            dilithium3_lib.pqcrystals_dilithium3_ref_polyz_pack(sig, ctypes.pointer(z[i]))
        if sec_level == 5:
            dilithium5_lib.pqcrystals_dilithium5_ref_polyz_pack(sig, ctypes.pointer(z[i]))

        full_sig += bytes(sig)

    return full_sig
