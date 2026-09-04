//! ML-DSA-65 (FIPS 204) safe wrappers
//!
//! Provides safe Rust wrappers for the ML-DSA-65 post-quantum digital signature algorithm.

use std::mem::MaybeUninit;

use crate::bindings::{self, *};
use crate::error::{QvError, Result};

/// ML-DSA-65 public key
#[derive(Clone)]
pub struct MlDsaPublicKey {
    inner: QvMlDsaPublicKey,
}

impl MlDsaPublicKey {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_MLDSA65_PK_SIZE]) -> Self {
        Self {
            inner: QvMlDsaPublicKey { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_MLDSA65_PK_SIZE] {
        &self.inner.bytes
    }

    /// Verify a signature
    pub fn verify(&self, message: &[u8], signature: &MlDsaSignature) -> Result<()> {
        let code = unsafe {
            bindings::qv_mldsa65_verify(
                &self.inner,
                message.as_ptr(),
                message.len(),
                &signature.inner,
            )
        };
        QvError::from_code(code)
    }

    /// Verify a signature, returning bool instead of Result
    pub fn verify_bool(&self, message: &[u8], signature: &MlDsaSignature) -> bool {
        self.verify(message, signature).is_ok()
    }
}

impl AsRef<[u8]> for MlDsaPublicKey {
    fn as_ref(&self) -> &[u8] {
        &self.inner.bytes
    }
}

/// ML-DSA-65 secret key
///
/// This type is automatically zeroed when dropped.
#[derive(Clone)]
pub struct MlDsaSecretKey {
    inner: QvMlDsaSecretKey,
}

impl MlDsaSecretKey {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_MLDSA65_SK_SIZE]) -> Self {
        Self {
            inner: QvMlDsaSecretKey { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_MLDSA65_SK_SIZE] {
        &self.inner.bytes
    }

    /// Sign a message with randomization (hedged signature)
    pub fn sign(&self, message: &[u8]) -> Result<MlDsaSignature> {
        self.sign_with_mode(message, true)
    }

    /// Sign a message deterministically
    pub fn sign_deterministic(&self, message: &[u8]) -> Result<MlDsaSignature> {
        self.sign_with_mode(message, false)
    }

    /// Sign a message with explicit randomization mode
    fn sign_with_mode(&self, message: &[u8], randomized: bool) -> Result<MlDsaSignature> {
        let mut signature = MaybeUninit::<QvMlDsaSignature>::uninit();
        let code = unsafe {
            bindings::qv_mldsa65_sign(
                &self.inner,
                message.as_ptr(),
                message.len(),
                signature.as_mut_ptr(),
                randomized,
            )
        };
        QvError::from_code(code)?;
        let signature = unsafe { signature.assume_init() };
        Ok(MlDsaSignature { inner: signature })
    }
}

impl Drop for MlDsaSecretKey {
    fn drop(&mut self) {
        unsafe {
            bindings::qv_secure_zero(self.inner.bytes.as_mut_ptr(), QV_MLDSA65_SK_SIZE);
        }
    }
}

/// ML-DSA-65 key pair
pub struct MlDsaKeyPair {
    /// Public key
    pub pk: MlDsaPublicKey,
    /// Secret key
    pub sk: MlDsaSecretKey,
}

impl MlDsaKeyPair {
    /// Generate a new key pair from random seed
    pub fn generate() -> Result<Self> {
        Self::generate_from_seed(None)
    }

    /// Generate a key pair from a specific seed (for deterministic key generation)
    pub fn generate_from_seed(seed: Option<&[u8; QV_MLDSA65_SEED_SIZE]>) -> Result<Self> {
        let mut keypair = MaybeUninit::<QvMlDsaKeyPair>::uninit();
        let seed_ptr = seed.map(|s| s as *const _).unwrap_or(std::ptr::null());
        let code = unsafe { bindings::qv_mldsa65_keygen(keypair.as_mut_ptr(), seed_ptr) };
        QvError::from_code(code)?;
        let keypair = unsafe { keypair.assume_init() };
        Ok(Self {
            pk: MlDsaPublicKey { inner: keypair.pk },
            sk: MlDsaSecretKey { inner: keypair.sk },
        })
    }

    /// Get the public key
    pub fn public_key(&self) -> &MlDsaPublicKey {
        &self.pk
    }

    /// Get the secret key
    pub fn secret_key(&self) -> &MlDsaSecretKey {
        &self.sk
    }
}

/// ML-DSA-65 signature
#[derive(Clone)]
pub struct MlDsaSignature {
    inner: QvMlDsaSignature,
}

impl MlDsaSignature {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_MLDSA65_SIG_SIZE]) -> Self {
        Self {
            inner: QvMlDsaSignature { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_MLDSA65_SIG_SIZE] {
        &self.inner.bytes
    }
}

impl AsRef<[u8]> for MlDsaSignature {
    fn as_ref(&self) -> &[u8] {
        &self.inner.bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keygen() {
        let keypair = MlDsaKeyPair::generate().expect("keygen should succeed");
        assert_eq!(keypair.pk.as_bytes().len(), QV_MLDSA65_PK_SIZE);
        assert_eq!(keypair.sk.as_bytes().len(), QV_MLDSA65_SK_SIZE);
    }

    /// NIST ACVP ML-DSA-65 keyGen vector (ACVP-Server gen-val
    /// ML-DSA-keyGen-FIPS204/internalProjection.json, tcId 26 — the same
    /// vector `src/ml_dsa_tier1_anchors.zig` pins), driven through the linked
    /// library. A library built from pre-final FIPS 204 source expands the
    /// seed as SHAKE256(ξ) instead of SHAKE256(ξ ‖ k ‖ ℓ) and produces a
    /// different ρ (pk[0..32]) and t1; this test catches exactly that.
    #[test]
    fn kat_nist_keygen_fips204_final() {
        fn hex<const N: usize>(s: &str) -> [u8; N] {
            assert_eq!(s.len(), 2 * N, "hex length");
            let mut out = [0u8; N];
            for (i, b) in out.iter_mut().enumerate() {
                *b = u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap();
            }
            out
        }
        let seed = hex::<QV_MLDSA65_SEED_SIZE>("1BD67DC782B2958E189E315C040DD1F64C8AB232A6A170E1A7A52C33F10851B1");
        let kp = MlDsaKeyPair::generate_from_seed(Some(&seed)).expect("keygen from seed");
        assert_eq!(kp.pk.as_bytes(), &hex::<QV_MLDSA65_PK_SIZE>(NIST_KG_PK_HEX));
    }

    const NIST_KG_PK_HEX: &str = "43AD6560D3BB684667A559EE6EC7C816020E5B65671F270F2353A8C912B6C26B0DB0C2CF42DC747B10AA3EBDD573B300EEA46C4200B210094F9512119A6BB837242762B2CE94C2467278500EE7B139BED906676663355B813A9AD9D3DB70F7AF2D785040BFD51208BD3D2CFB09EAF7CEDF77D1B59DA75F7728F120C11898D9EC2CB22C73EB8F9436FF60524B56EE6B413030EB7DD10774261452CD8C5ADE75D1967628078CDA77E2B1AFB83B9F07F6939D37FF54D5E10ED17FF8A3C21546A89F514576AE780DE8761C4F2EA28828C69E38C730ACAA4CC8DC7DF63BA4C1525510FAE2C8E1B01812358BC5DFC01E955294A5DFDD1CFF0519E20B8F74FE18854D80C86051AA5CC2FC1DB078BC785BF4BAD6832B8C269156509B332038B4C3719DC49814FC6B6AD5360E945AFFF4D4AC235F56C7F7A9A872B518C1F0D48184DA0EB318F74EB84C4F324A2BD03704D2E2A59F64A8854C7AEFB2D3530E20C8AE8A487E6CBEDA645BD86A5A83E77A6A22888ED8E43A7F4804C2DE187F1ACBA3CF55CF99412A7A59CF77A4A977724A72686FDF7FC64492A5CB75921AD014EB727EDA1DFA7BD7ACE52FE292322F0BE0B004DCE44BEAA20FF06A7691DC36405361F9240DDF2FD1A5EC422ED639505AB8E137B971D5729B11E84C040247424A51DDDBDBC43AF261D038B0CD70D5BF44252A3786A26AF3FCD4EC100E5CDDE019F17BE6A64F820C3F622F78D4F56A984122D6FA2D438D548DD87B9095F1FF02437854E2419A0316C33EAFFA0161737E476A9E707CC40E78686D6A043DDE962B319BE2BF9F7A1EFF9EDEFD1B4CD07131494C084083BF76181E3EB1399929314473A75E199AC9D5444DB0CEC07E625EC70C6864093961950987FB1E96DCB7E001209865D66D829CD2E2B240818CACE003C9CC74DCE5151C65E59AC1EF6D495B0C717B4412C70B50CF44F44E648788F46BAF6F8AF3361F0E4B6119EDF6374DA596453169B935E1A3B875A6C1B9FE384AF961860514E8CF291D8650D7530DB42A46790649B5D8134AAEC33A41F0AB4296AE26203291F1C2BB5276AC305269778E7F2A4BAC15B5A31A6B6B76342596D39C7FD3D1C518689372EBD20B667BE5EE2ED11BC107A7600EDA1BE7A5DC05BB9F16D2B8BB1C7D8D10050207530BFFDAAE7B11E0615726F2E99CE99D6CA6048F9D61B14F7265473EC2D02989772B3D7E212AA68D89374C6CAF7AB160C6C5E09502049C3D03738D700457F706341DDEAFC6CA739ECFB4F193EA6B385B035EEA0F7BFD61FA776AF32AED6366E6C0642D1A01759FA6BDD295F7D18CA6DA1D48563EEE403F2F8BCB6A60326C481F12F8180B2B8117ADE61C7E29F5254207C5D4657B82BE4EBA436752EC7DA0627FCED830C15F10FB8D3CD90B4505FA325B54D954C5B6301DA72B262B226EAB2E4EE88226CC606B97736260ECB6D8F74A0440AFD5D751A90873FFF00C8D3E9CA0975F303F7AC263B8FF496C6C8FD22E8EF7B587BAB50A7DAD99BD55D3B7968584F1FB21255EE22DB56AF6034F3F13E659161A57CA8C9F2E87CA96BD7100FCEF8F74A8C6A1C92E2EFF74E2F5FAE512C09D26E0F3985D882401EFC54727BBC0F4E1110771A106898692D0C5A6997CA742846FA4D49E8ABDF123D92743E9949BEB6E46B9655EE698C23D74991C96067DEF06EACB981AD4A7A5ED91EACF05D374C74C443F3FBAD363B2450A1A47AAF2954D36E53B06345139138D38B941298982EEA84400C4DCC38F5127951906EE3E40F75A5DFE09FCE9BB0143A5D5ADC3C402F23A75A423AB98392CA3A4D5D23D3BCD56FF22C9612A5D2C223C7079958CD05175AA74DDD21B42051CDBDC14048CB43CB2F6535E2CA9F5B87052F633976F4795CBA69D39F2481CFB9D210C9B0E9EFD941AC875A9A6C3E839EC54F55585721DE41815DDFC05E8A58C97E2FA52984135AAB0931094FF8400CAB043C2A5E63C2942B7D36988C4ED9B73C11D913E758ADF94291A42743E4FB04C271ED5807EA03271EA6656CF967AB2595588B55F82AF2D07ADFFCCF859ABA70B1707B722DA1FF393CC5BBCC02014C0D4500655577946DB5F95EF1E7657DC98402E5CB048DCB372C9277FDA4D8F3A30C953822474CEEDA670D5E680029259260D91F8737CF7572651FB28A7DF46F671679BDD507696B021C2C7F4300F3098FF9460582DB58E122C585185BCD091E7ACCB608F7E0C3558627484529A662C0528D419248B6565D32ECC78F7891DB5BB1984CDE89C1AF25F0927205E734A7DFEB9AEE94F23F2FD11FB53EC768F6B8268E00E4054CD12EDE4832B07A254A4E2241854E8FF2AE1E1B248F9EB1C77581CA2A2EF2D4C9171177A1E040F9D4AD8D0D0C6CD14FCD13B233794E51704B6890C56BCE1B8CD1C9EAE6D59ACD91EB67B3A618D65F0F94E5458271E14DC6F6530AD0EE8B2B2F0CEC14612E563338E241602B997EC4E62C83942C7F18DAD6841B1348CAB99A78F598FE78A20205D88D826D2E163F6B628B266C187B427F253000E4EF99FEC0494A97D9B42E37EE613767D2651FB7CB2B9E99578CE2D78B9C9777C954DBD1D7BE8B568F88AB42DDFD293BE28747103B052AD81D8F6254E426802516500111ADF0A8F27AE7C55D3D5DB86278FAF58B68A26D12B2801AC28EDA87AA5D692EDA9BE08F7CC3E78517299A3FD9CE2A0A893E12D71062AE2514C465D399F165E4D2F71D1913D8B95396681486432B090F0CCE86AA84B661FF22D4A56035E821A1CE30F33AFEB6C7B8FA9CE";

    #[test]
    fn test_sign_verify() {
        let keypair = MlDsaKeyPair::generate().expect("keygen should succeed");
        let message = b"Hello, quantum world!";

        // Sign
        let signature = keypair.sk.sign(message).expect("signing should succeed");

        // Verify
        keypair
            .pk
            .verify(message, &signature)
            .expect("verification should succeed");
    }

    #[test]
    fn test_sign_verify_deterministic() {
        let keypair = MlDsaKeyPair::generate().expect("keygen should succeed");
        let message = b"Deterministic signature test";

        // Sign deterministically
        let sig1 = keypair
            .sk
            .sign_deterministic(message)
            .expect("signing should succeed");
        let sig2 = keypair
            .sk
            .sign_deterministic(message)
            .expect("signing should succeed");

        // Deterministic signatures should be identical
        assert_eq!(sig1.as_bytes(), sig2.as_bytes());

        // Verify
        keypair.pk.verify(message, &sig1).expect("verification should succeed");
    }

    #[test]
    fn test_verify_wrong_message() {
        let keypair = MlDsaKeyPair::generate().expect("keygen should succeed");
        let message = b"Original message";
        let wrong_message = b"Wrong message";

        let signature = keypair.sk.sign(message).expect("signing should succeed");

        // Verification should fail with wrong message
        assert!(keypair.pk.verify(wrong_message, &signature).is_err());
    }

    #[test]
    fn test_deterministic_keygen() {
        let seed = [42u8; QV_MLDSA65_SEED_SIZE];

        let kp1 = MlDsaKeyPair::generate_from_seed(Some(&seed)).expect("keygen should succeed");
        let kp2 = MlDsaKeyPair::generate_from_seed(Some(&seed)).expect("keygen should succeed");

        // Same seed should produce same keys
        assert_eq!(kp1.pk.as_bytes(), kp2.pk.as_bytes());
        assert_eq!(kp1.sk.as_bytes(), kp2.sk.as_bytes());
    }

    #[test]
    fn test_key_roundtrip() {
        let keypair = MlDsaKeyPair::generate().expect("keygen should succeed");
        let message = b"Roundtrip test message";

        // Export and reimport public key
        let pk_bytes = keypair.pk.as_bytes();
        let pk2 = MlDsaPublicKey::from_bytes(pk_bytes);

        // Sign with original key, verify with reimported key
        let signature = keypair.sk.sign(message).expect("signing should succeed");
        pk2.verify(message, &signature).expect("verification should succeed");
    }
}
