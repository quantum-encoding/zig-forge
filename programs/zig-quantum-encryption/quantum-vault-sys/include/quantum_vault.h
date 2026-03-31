/**
 * Quantum Vault Post-Quantum Cryptography Library
 *
 * FIPS 203 (ML-KEM-768) + FIPS 204 (ML-DSA-65) + Hybrid ML-KEM+X25519
 *
 * Auto-generated from quantum_vault_ffi.zig
 * Do not edit manually.
 *
 * Version: 1.0.0
 */

#ifndef QUANTUM_VAULT_H
#define QUANTUM_VAULT_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ========================================================================== */
/* Size Constants                                                              */
/* ========================================================================== */

/* ML-KEM-768 (FIPS 203) */
#define QV_MLKEM768_EK_SIZE   1184   /* Encapsulation key (public) */
#define QV_MLKEM768_DK_SIZE   2400   /* Decapsulation key (private) */
#define QV_MLKEM768_CT_SIZE   1088   /* Ciphertext */
#define QV_MLKEM768_SS_SIZE   32     /* Shared secret */

/* ML-DSA-65 (FIPS 204) */
#define QV_MLDSA65_PK_SIZE    1952   /* Public key */
#define QV_MLDSA65_SK_SIZE    4032   /* Secret key */
#define QV_MLDSA65_SIG_SIZE   3309   /* Signature */
#define QV_MLDSA65_SEED_SIZE  32     /* Seed */

/* Hybrid ML-KEM-768 + X25519 */
#define QV_HYBRID_EK_SIZE     1216   /* Encapsulation key */
#define QV_HYBRID_DK_SIZE     2432   /* Decapsulation key */
#define QV_HYBRID_CT_SIZE     1120   /* Ciphertext */
#define QV_HYBRID_SS_SIZE     32     /* Shared secret */

/* ========================================================================== */
/* Error Codes                                                                 */
/* ========================================================================== */

typedef enum {
    QV_SUCCESS = 0,

    /* General errors (-1 to -9) */
    QV_INVALID_PARAMETER = -1,
    QV_RNG_FAILURE = -2,
    QV_MEMORY_ERROR = -3,

    /* ML-KEM errors (-10 to -19) */
    QV_MLKEM_INVALID_EK = -10,
    QV_MLKEM_INVALID_DK = -11,
    QV_MLKEM_INVALID_CT = -12,
    QV_MLKEM_ENCAPS_FAILED = -13,
    QV_MLKEM_DECAPS_FAILED = -14,
    QV_MLKEM_KEYGEN_FAILED = -15,

    /* ML-DSA errors (-20 to -29) */
    QV_MLDSA_INVALID_PK = -20,
    QV_MLDSA_INVALID_SK = -21,
    QV_MLDSA_INVALID_SIG = -22,
    QV_MLDSA_SIGNING_FAILED = -23,
    QV_MLDSA_VERIFICATION_FAILED = -24,
    QV_MLDSA_KEYGEN_FAILED = -25,

    /* Hybrid errors (-30 to -39) */
    QV_HYBRID_KEYGEN_FAILED = -30,
    QV_HYBRID_ENCAPS_FAILED = -31,
    QV_HYBRID_DECAPS_FAILED = -32,
    QV_HYBRID_INVALID_PK = -33
} QvError;

/* ========================================================================== */
/* ML-KEM-768 Types                                                            */
/* ========================================================================== */

typedef struct { uint8_t data[QV_MLKEM768_EK_SIZE]; } QvMlKemEncapsKey;
typedef struct { uint8_t data[QV_MLKEM768_DK_SIZE]; } QvMlKemDecapsKey;
typedef struct { uint8_t data[QV_MLKEM768_CT_SIZE]; } QvMlKemCiphertext;

typedef struct {
    QvMlKemEncapsKey ek;
    QvMlKemDecapsKey dk;
} QvMlKemKeyPair;

typedef struct {
    uint8_t shared_secret[QV_MLKEM768_SS_SIZE];
    QvMlKemCiphertext ciphertext;
} QvMlKemEncapsResult;

/* ========================================================================== */
/* ML-DSA-65 Types                                                             */
/* ========================================================================== */

typedef struct { uint8_t data[QV_MLDSA65_PK_SIZE]; } QvMlDsaPublicKey;
typedef struct { uint8_t data[QV_MLDSA65_SK_SIZE]; } QvMlDsaSecretKey;
typedef struct { uint8_t data[QV_MLDSA65_SIG_SIZE]; } QvMlDsaSignature;

typedef struct {
    QvMlDsaPublicKey pk;
    QvMlDsaSecretKey sk;
} QvMlDsaKeyPair;

/* ========================================================================== */
/* Hybrid Types                                                                */
/* ========================================================================== */

typedef struct { uint8_t data[QV_HYBRID_EK_SIZE]; } QvHybridEncapsKey;
typedef struct { uint8_t data[QV_HYBRID_DK_SIZE]; } QvHybridDecapsKey;
typedef struct { uint8_t data[QV_HYBRID_CT_SIZE]; } QvHybridCiphertext;

typedef struct {
    QvHybridEncapsKey ek;
    QvHybridDecapsKey dk;
} QvHybridKeyPair;

typedef struct {
    uint8_t shared_secret[QV_HYBRID_SS_SIZE];
    QvHybridCiphertext ciphertext;
} QvHybridEncapsResult;

/* ========================================================================== */
/* ML-KEM-768 API                                                              */
/* ========================================================================== */

/**
 * Generate ML-KEM-768 key pair for key encapsulation.
 *
 * @param keypair Output: generated key pair
 * @return QV_SUCCESS on success, error code on failure
 */
QvError qv_mlkem768_keygen(QvMlKemKeyPair* keypair);

/**
 * Encapsulate: generate shared secret and ciphertext.
 *
 * @param ek Input: encapsulation key (public)
 * @param result Output: shared secret and ciphertext
 * @return QV_SUCCESS on success, error code on failure
 */
QvError qv_mlkem768_encaps(const QvMlKemEncapsKey* ek, QvMlKemEncapsResult* result);

/**
 * Decapsulate: recover shared secret from ciphertext.
 *
 * @param dk Input: decapsulation key (private)
 * @param ct Input: ciphertext
 * @param shared_secret Output: 32-byte shared secret
 * @return QV_SUCCESS on success, error code on failure
 */
QvError qv_mlkem768_decaps(const QvMlKemDecapsKey* dk, const QvMlKemCiphertext* ct,
                           uint8_t shared_secret[QV_MLKEM768_SS_SIZE]);

/* ========================================================================== */
/* ML-DSA-65 API                                                               */
/* ========================================================================== */

/**
 * Generate ML-DSA-65 key pair with optional deterministic seed.
 *
 * @param keypair Output: generated key pair
 * @param seed Input: optional 32-byte seed (NULL for random)
 * @return QV_SUCCESS on success, error code on failure
 */
QvError qv_mldsa65_keygen(QvMlDsaKeyPair* keypair, const uint8_t seed[QV_MLDSA65_SEED_SIZE]);

/**
 * Generate ML-DSA-65 key pair with random seed.
 */
QvError qv_mldsa65_keygen_random(QvMlDsaKeyPair* keypair);

/**
 * Sign message with ML-DSA-65.
 *
 * @param sk Input: secret key
 * @param message Input: message to sign
 * @param message_len Input: message length
 * @param signature Output: signature
 * @param randomized Input: true for randomized signing
 * @return QV_SUCCESS on success, error code on failure
 */
QvError qv_mldsa65_sign(const QvMlDsaSecretKey* sk, const uint8_t* message,
                        size_t message_len, QvMlDsaSignature* signature, bool randomized);

/**
 * Sign message with randomized ML-DSA-65.
 */
QvError qv_mldsa65_sign_randomized(const QvMlDsaSecretKey* sk, const uint8_t* message,
                                   size_t message_len, QvMlDsaSignature* signature);

/**
 * Sign message with deterministic ML-DSA-65.
 */
QvError qv_mldsa65_sign_deterministic(const QvMlDsaSecretKey* sk, const uint8_t* message,
                                      size_t message_len, QvMlDsaSignature* signature);

/**
 * Verify ML-DSA-65 signature.
 *
 * @param pk Input: public key
 * @param message Input: signed message
 * @param message_len Input: message length
 * @param signature Input: signature to verify
 * @return QV_SUCCESS if valid, QV_MLDSA_VERIFICATION_FAILED if invalid
 */
QvError qv_mldsa65_verify(const QvMlDsaPublicKey* pk, const uint8_t* message,
                          size_t message_len, const QvMlDsaSignature* signature);

/* ========================================================================== */
/* Hybrid API                                                                  */
/* ========================================================================== */

/**
 * Generate hybrid key pair (ML-KEM-768 + X25519).
 *
 * @param keypair Output: generated key pair
 * @return QV_SUCCESS on success, error code on failure
 */
QvError qv_hybrid_keygen(QvHybridKeyPair* keypair);

/**
 * Hybrid encapsulation: generate combined shared secret.
 *
 * @param ek Input: encapsulation key
 * @param result Output: shared secret and ciphertext
 * @return QV_SUCCESS on success, error code on failure
 */
QvError qv_hybrid_encaps(const QvHybridEncapsKey* ek, QvHybridEncapsResult* result);

/**
 * Hybrid decapsulation: recover combined shared secret.
 *
 * @param dk Input: decapsulation key
 * @param ct Input: ciphertext
 * @param shared_secret Output: 32-byte shared secret
 * @return QV_SUCCESS on success, error code on failure
 */
QvError qv_hybrid_decaps(const QvHybridDecapsKey* dk, const QvHybridCiphertext* ct,
                         uint8_t shared_secret[QV_HYBRID_SS_SIZE]);

/* ========================================================================== */
/* Utility Functions                                                           */
/* ========================================================================== */

/**
 * Securely zero memory (prevents compiler optimization).
 */
void qv_secure_zero(uint8_t* ptr, size_t len);

/**
 * Constant-time comparison (prevents timing attacks).
 */
bool qv_constant_time_eq(const uint8_t* a, const uint8_t* b, size_t len);

/**
 * Get library version string.
 */
const char* qv_version(void);

/* ========================================================================== */
/* Size Query Functions                                                        */
/* ========================================================================== */

size_t qv_mlkem768_ek_size(void);
size_t qv_mlkem768_dk_size(void);
size_t qv_mlkem768_ct_size(void);
size_t qv_mlkem768_ss_size(void);
size_t qv_mldsa65_pk_size(void);
size_t qv_mldsa65_sk_size(void);
size_t qv_mldsa65_sig_size(void);
size_t qv_hybrid_ek_size(void);
size_t qv_hybrid_dk_size(void);
size_t qv_hybrid_ct_size(void);
size_t qv_hybrid_ss_size(void);

#ifdef __cplusplus
}
#endif

#endif /* QUANTUM_VAULT_H */