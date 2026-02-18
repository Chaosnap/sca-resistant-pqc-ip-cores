# SCA Resistant PQC IP Cores

**Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>.**

Unified masked hardware architecture of ML-KEM (Kyber) and ML-DSA (Dilithium) compliant with NIST standards [FIPS203](https://doi.org/10.6028/NIST.FIPS.203) and [FIPS204](https://doi.org/10.6028/NIST.FIPS.204). It is based on the unprotected design [DiKy](https://gitlab.com/brno-axe/pqc/diky).

## Project Acknowledgement
This project was funded under Grant Agreement No. 101225691 and is supported by the European Cybersecurity Competence Centre.

**Disclaimer**:
Funded by the European Union. Views and opinions expressed are those of the author(s) only and do not necessarily reflect those of the European Union or the European Cybersecurity Competence Centre. Neither the European Union nor the granting authority can be held responsible for them.

## Testing
All components are tested using [cocotb](https://www.cocotb.org) framework against reference implementations of [Kyber](https://github.com/pq-crystals/kyber/tree/10b478fc3cc4ff6215eb0b6a11bd758bf0929cbd) and [Dilithium](https://github.com/pq-crystals/dilithium/tree/444cdcc84eb36b66fe27b3a2529ee48f6d8150c2).
To run these tests you need to generate shared libraries for these implementations and place them in folder `libs`. It is also required to expose seed used during Dilithium's key generation and functions for rejection sampling. This can be done with following changes.

<details>
<summary>Changes in Kyber</summary>

```diff
--- a/ref/indcpa.c
+++ b/ref/indcpa.c
@@ -118,7 +118,7 @@ static void unpack_ciphertext(polyvec *b, poly *v, const uint8_t c[KYBER_INDCPA_
 *
 * Returns number of sampled 16-bit integers (at most len)
 **************************************************/
-static unsigned int rej_uniform(int16_t *r,
+unsigned int rej_uniform(int16_t *r,
```

```diff
--- a/ref/indcpa.h
+++ b/ref/indcpa.h
@@ -5,6 +5,12 @@
 #include "params.h"
 #include "polyvec.h"
 
+#define rej_uniform KYBER_NAMESPACE(rej_uniform)
+unsigned int rej_uniform(int16_t *r,
+                                unsigned int len,
+                                const uint8_t *buf,
+                                unsigned int buflen);
+
```

</details>

<details>
<summary>Changes in Dilithium</summary>

```diff
--- a/ref/poly.c
+++ b/ref/poly.c
@@ -306,7 +306,7 @@ int poly_chknorm(const poly *a, int32_t B) {
 * Returns number of sampled coefficients. Can be smaller than len if not enough
 * random bytes were given.
 **************************************************/
-static unsigned int rej_uniform(int32_t *a,
+unsigned int rej_uniform(int32_t *a,
                                 unsigned int len,
                                 const uint8_t *buf,
                                 unsigned int buflen)
@@ -381,7 +381,7 @@ void poly_uniform(poly *a,
 * Returns number of sampled coefficients. Can be smaller than len if not enough
 * random bytes were given.
 **************************************************/
-static unsigned int rej_eta(int32_t *a,
+unsigned int rej_eta(int32_t *a,
                             unsigned int len,
                             const uint8_t *buf,
                             unsigned int buflen)
@@ -396,11 +396,11 @@ static unsigned int rej_eta(int32_t *a,
     t1 = buf[pos++] >> 4;
 
 #if ETA == 2
-    if(t0 < 15) {
+    if(t0 < 5) {
       t0 = t0 - (205*t0 >> 10)*5;
       a[ctr++] = 2 - t0;
     }
-    if(t1 < 15 && ctr < len) {
+    if(t1 < 5 && ctr < len) {
       t1 = t1 - (205*t1 >> 10)*5;
       a[ctr++] = 2 - t1;
     }
```

```diff
--- a/ref/poly.h
+++ b/ref/poly.h
@@ -8,6 +8,17 @@ typedef struct {
   int32_t coeffs[N];
 } poly;
 
+#define rej_uniform DILITHIUM_NAMESPACE(rej_uniform)
+unsigned int rej_uniform(int32_t *a,
+                                unsigned int len,
+                                const uint8_t *buf,
+                                unsigned int buflen);
+#define rej_eta DILITHIUM_NAMESPACE(rej_eta)
+unsigned int rej_eta(int32_t *a,
+                            unsigned int len,
+                            const uint8_t *buf,
+                            unsigned int buflen);
+
```

```diff
--- a/ref/sign.c
+++ b/ref/sign.c
@@ -20,7 +20,7 @@
 *
 * Returns 0 (success)
 **************************************************/
-int crypto_sign_keypair(uint8_t *pk, uint8_t *sk) {
+int crypto_sign_keypair(uint8_t *pk, uint8_t *sk, uint8_t *seed) {
   uint8_t seedbuf[2*SEEDBYTES + CRHBYTES];
   uint8_t tr[TRBYTES];
   const uint8_t *rho, *rhoprime, *key;
@@ -30,6 +30,8 @@ int crypto_sign_keypair(uint8_t *pk, uint8_t *sk) {
 
   /* Get randomness for rho, rhoprime and key */
   randombytes(seedbuf, SEEDBYTES);
+  for (size_t i = 0; i < SEEDBYTES; i++)
+    seed[i] = seedbuf[i];
```

```diff
--- a/ref/sign.h
+++ b/ref/sign.h
@@ -8,7 +8,7 @@
 #include "poly.h"
 
 #define crypto_sign_keypair DILITHIUM_NAMESPACE(keypair)
-int crypto_sign_keypair(uint8_t *pk, uint8_t *sk);
+int crypto_sign_keypair(uint8_t *pk, uint8_t *sk, uint8_t *seed);
```

</details>

### Setup
To setup the testing environment Python3.7 and [nvc](https://github.com/nickg/nvc) are required. Additional required libraries are specified in [requirements.txt](./requirements.txt).

