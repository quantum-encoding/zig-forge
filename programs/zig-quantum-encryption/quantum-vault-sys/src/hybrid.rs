//! Hybrid ML-KEM-768 + X25519 safe wrappers
//!
//! Provides safe Rust wrappers for the hybrid key encapsulation mechanism that combines
//! post-quantum ML-KEM-768 with classical X25519 for defense-in-depth.

use std::mem::MaybeUninit;

use crate::bindings::{self, *};
use crate::error::{QvError, Result};
use crate::secure::SecureBytes;

/// Hybrid encapsulation key (public key)
///
/// This combines an ML-KEM-768 public key with an X25519 public key.
#[derive(Clone)]
pub struct HybridEncapsKey {
    inner: QvHybridEncapsKey,
}

impl HybridEncapsKey {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_HYBRID_EK_SIZE]) -> Self {
        Self {
            inner: QvHybridEncapsKey { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_HYBRID_EK_SIZE] {
        &self.inner.bytes
    }

    /// Encapsulate with the **v1** combiner:
    /// `K = SHA3-256("HYBRID-ML-KEM-768-X25519-v1" || ss_M || ss_X)`.
    ///
    /// Only for producing data that a not-yet-updated v1 reader must open.
    /// New data should use [`encaps_v2`](Self::encaps_v2). The ciphertext
    /// layout is identical across versions; only the shared secret differs.
    pub fn encaps(&self) -> Result<HybridEncapsResult> {
        self.encaps_with(bindings::qv_hybrid_encaps)
    }

    /// Encapsulate with the **v2** combiner (recommended):
    /// `K = HKDF-SHA3-256(salt = "", IKM = ss_M || ss_X || ct_X || pk_X,
    /// info = "HYBRID-ML-KEM-768-X25519-v2", L = 32)`, binding both X25519
    /// public keys into the secret. Decapsulate with
    /// [`HybridDecapsKey::decaps_v2`]. Full definition: `docs/HYBRID-V2.md`.
    pub fn encaps_v2(&self) -> Result<HybridEncapsResult> {
        self.encaps_with(bindings::qv_hybrid_encaps_v2)
    }

    fn encaps_with(
        &self,
        f: unsafe extern "C" fn(*const QvHybridEncapsKey, *mut QvHybridEncapsResult) -> std::os::raw::c_int,
    ) -> Result<HybridEncapsResult> {
        let mut result = MaybeUninit::<QvHybridEncapsResult>::uninit();
        let code = unsafe { f(&self.inner, result.as_mut_ptr()) };
        QvError::from_code(code)?;
        let result = unsafe { result.assume_init() };
        Ok(HybridEncapsResult {
            shared_secret: SecureBytes::from_array(result.shared_secret),
            ciphertext: HybridCiphertext {
                inner: result.ciphertext,
            },
        })
    }
}

impl AsRef<[u8]> for HybridEncapsKey {
    fn as_ref(&self) -> &[u8] {
        &self.inner.bytes
    }
}

/// Hybrid decapsulation key (private key)
///
/// This type is automatically zeroed when dropped.
#[derive(Clone)]
pub struct HybridDecapsKey {
    inner: QvHybridDecapsKey,
}

impl HybridDecapsKey {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_HYBRID_DK_SIZE]) -> Self {
        Self {
            inner: QvHybridDecapsKey { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_HYBRID_DK_SIZE] {
        &self.inner.bytes
    }

    /// Decapsulate a ciphertext to recover the shared secret
    ///
    /// This performs both ML-KEM decapsulation and X25519 key agreement,
    /// combining the results with SHA3-256.
    pub fn decaps(&self, ciphertext: &HybridCiphertext) -> Result<SecureBytes<QV_HYBRID_SS_SIZE>> {
        let mut shared_secret = [0u8; QV_HYBRID_SS_SIZE];
        let code = unsafe {
            bindings::qv_hybrid_decaps(&self.inner, &ciphertext.inner, &mut shared_secret)
        };
        QvError::from_code(code)?;
        Ok(SecureBytes::from_array(shared_secret))
    }
}

impl Drop for HybridDecapsKey {
    fn drop(&mut self) {
        unsafe {
            bindings::qv_secure_zero(self.inner.bytes.as_mut_ptr(), QV_HYBRID_DK_SIZE);
        }
    }
}

/// Hybrid key pair
pub struct HybridKeyPair {
    /// Encapsulation key (public)
    pub ek: HybridEncapsKey,
    /// Decapsulation key (private)
    pub dk: HybridDecapsKey,
}

impl HybridKeyPair {
    /// Generate a new hybrid key pair
    pub fn generate() -> Result<Self> {
        let mut keypair = MaybeUninit::<QvHybridKeyPair>::uninit();
        let code = unsafe { bindings::qv_hybrid_keygen(keypair.as_mut_ptr()) };
        QvError::from_code(code)?;
        let keypair = unsafe { keypair.assume_init() };
        Ok(Self {
            ek: HybridEncapsKey { inner: keypair.ek },
            dk: HybridDecapsKey { inner: keypair.dk },
        })
    }

    /// Get the encapsulation key (public key)
    pub fn encaps_key(&self) -> &HybridEncapsKey {
        &self.ek
    }

    /// Get the decapsulation key (private key)
    pub fn decaps_key(&self) -> &HybridDecapsKey {
        &self.dk
    }
}

/// Hybrid ciphertext
#[derive(Clone)]
pub struct HybridCiphertext {
    inner: QvHybridCiphertext,
}

impl HybridCiphertext {
    /// Create from raw bytes
    pub fn from_bytes(bytes: &[u8; QV_HYBRID_CT_SIZE]) -> Self {
        Self {
            inner: QvHybridCiphertext { bytes: *bytes },
        }
    }

    /// Get the raw bytes
    pub fn as_bytes(&self) -> &[u8; QV_HYBRID_CT_SIZE] {
        &self.inner.bytes
    }
}

impl AsRef<[u8]> for HybridCiphertext {
    fn as_ref(&self) -> &[u8] {
        &self.inner.bytes
    }
}

/// Result of hybrid encapsulation
pub struct HybridEncapsResult {
    /// The combined shared secret (32 bytes)
    pub shared_secret: SecureBytes<QV_HYBRID_SS_SIZE>,
    /// The ciphertext to send to the recipient
    pub ciphertext: HybridCiphertext,
}

impl HybridDecapsKey {
    /// Decapsulate a ciphertext produced by [`HybridEncapsKey::encaps_v2`]
    /// (v2 combiner). Using this on a v1 ciphertext, or `decaps` on a v2 one,
    /// returns a different, useless secret rather than an error — the
    /// ciphertext carries no version marker.
    pub fn decaps_v2(&self, ciphertext: &HybridCiphertext) -> Result<SecureBytes<QV_HYBRID_SS_SIZE>> {
        let mut shared_secret = [0u8; QV_HYBRID_SS_SIZE];
        let code = unsafe {
            bindings::qv_hybrid_decaps_v2(&self.inner, &ciphertext.inner, &mut shared_secret)
        };
        QvError::from_code(code)?;
        Ok(SecureBytes::from_array(shared_secret))
    }
}

/// The bare v2 combiner, for cross-implementation known-answer tests:
/// `HKDF-SHA3-256(salt = "", IKM = ss_m || ss_x || ct_x || pk_x,
/// info = "HYBRID-ML-KEM-768-X25519-v2", L = 32)`. Not needed for normal use.
pub fn combine_v2(ss_m: &[u8; 32], ss_x: &[u8; 32], ct_x: &[u8; 32], pk_x: &[u8; 32]) -> SecureBytes<QV_HYBRID_SS_SIZE> {
    let mut out = [0u8; QV_HYBRID_SS_SIZE];
    unsafe { bindings::qv_hybrid_combine_v2(ss_m, ss_x, ct_x, pk_x, &mut out) };
    SecureBytes::from_array(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex<const N: usize>(s: &str) -> [u8; N] {
        let s: String = s.split_whitespace().collect();
        assert_eq!(s.len(), 2 * N, "hex length");
        let mut out = [0u8; N];
        for (i, b) in out.iter_mut().enumerate() {
            *b = u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap();
        }
        out
    }

    #[test]
    fn test_keygen() {
        let keypair = HybridKeyPair::generate().expect("keygen should succeed");
        assert_eq!(keypair.ek.as_bytes().len(), QV_HYBRID_EK_SIZE);
        assert_eq!(keypair.dk.as_bytes().len(), QV_HYBRID_DK_SIZE);
    }

    #[test]
    fn test_encaps_decaps_v2() {
        let keypair = HybridKeyPair::generate().expect("keygen should succeed");
        let encaps_result = keypair.ek.encaps_v2().expect("encaps_v2 should succeed");
        let shared_secret = keypair
            .dk
            .decaps_v2(&encaps_result.ciphertext)
            .expect("decaps_v2 should succeed");
        assert_eq!(encaps_result.shared_secret.as_bytes(), shared_secret.as_bytes());

        // The same ciphertext under the v1 combiner must not agree.
        let v1 = keypair.dk.decaps(&encaps_result.ciphertext).expect("decaps should succeed");
        assert_ne!(encaps_result.shared_secret.as_bytes(), v1.as_bytes());
    }

    /// Combiner-only KAT from docs/HYBRID-V2.md §5.1, expected value computed
    /// independently with Python hashlib/hmac.
    #[test]
    fn kat_combine_v2() {
        let ss_m: [u8; 32] = core::array::from_fn(|i| i as u8);
        let ss_x: [u8; 32] = core::array::from_fn(|i| 32 + i as u8);
        let ct_x: [u8; 32] = core::array::from_fn(|i| 64 + i as u8);
        let pk_x: [u8; 32] = core::array::from_fn(|i| 96 + i as u8);
        let k = combine_v2(&ss_m, &ss_x, &ct_x, &pk_x);
        assert_eq!(
            k.as_bytes(),
            &hex::<32>("22de6874d487bc9a0e2e68679f914ef2b3df2a4e4bb09a8ffed1095ce4dfd3e0")
        );
        let zero = [0u8; 32];
        let k0 = combine_v2(&ss_m, &zero, &ct_x, &pk_x);
        assert_eq!(
            k0.as_bytes(),
            &hex::<32>("3047921a56cb394acade1101753eb5ba5843f1ac8d6108eba9be2432f6b947be")
        );
    }

    /// Full-path vector from docs/HYBRID-V2.md §5.2: decapsulating the pinned
    /// (dk, ct) must give the pinned K under each version.
    #[test]
    fn kat_full_path_decaps() {
        let dk = HybridDecapsKey::from_bytes(&hex::<QV_HYBRID_DK_SIZE>(KAT_DK_HEX));
        let ct = HybridCiphertext::from_bytes(&hex::<QV_HYBRID_CT_SIZE>(KAT_CT_HEX));

        let k_v1 = dk.decaps(&ct).expect("decaps");
        assert_eq!(
            k_v1.as_bytes(),
            &hex::<32>("ece5edee3b04bc365a58066bc579e46de88ccb700fa20cdb44fd6289e9a56a02")
        );
        let k_v2 = dk.decaps_v2(&ct).expect("decaps_v2");
        assert_eq!(
            k_v2.as_bytes(),
            &hex::<32>("554119be4c831483f20bc6050d4e5c243a3e45fa91093bdd86e4a5fc1a64db5b")
        );
    }

    const KAT_DK_HEX: &str = "1b56936ef0793565421f8408bcb1ab4f850845b78f480809215b1255c315c388857d6359c938ae15f461d1c1aeb1314058871fb2d417d9711931439d00b031d80a3341a5551db08266e3a2c1f4a7408723638b47d4ac9b06702be4fc72e9fb78172c04041894674527e8e50f2e0968b221678f6171954cb0eaf0a9a4d7cec1dc4fc7c17ff1558fdd7b298f133786fac707d732eff9c4faf711dc1070d4b6c8f3e92ee0f12fc3f16ae0413cbea83cc6e8bddbea705f4a32d5f2607a67a0f09bad6ba50439912d0eb58e262bb3621b556409217b85ad81ab80b6eca4e51850c34cc4c8e4923a0b9f30bb318ad549d8177592426d90428f5f2179a7b78c45cc3050ec6634c52388db0ad4d1994fcc6f25e79101306e5aec3064a44b15847b48a1984f8053a0c95583e59d10202eb3d1196497cd7623132afaa84d9a45d6559eb803c563fb99f3fc13b85c81600b37e2e645a5f209693384aca97e71d991dbfa823fd64c2b9937de8301b0a5b461bbafbf0a0347cb793921c28fe34eec9c811dfbc048e36a3738b548850fd7439212946252376a2f5209999683654860e2083f74e915b397cf76eb34ddd611c5496592ec7c8c1006a3342a540b18e70a2dd76868b0e8b07d2b8e82283301b55b7b34ca85605f42a39f8e153b857a84e2aa8d0838071bc7648e889ca849724dcc4e8581b5834634b9b36a4861268c13193fc7b94104c57f62cd069cac44b46a8143acfe5a536a3a83130ca523ca90c5722dad78909090b5c2a5828e9c7688a3503775c068a131bdf24a6362a6d680ba332749d1e15b3ad369f35a1fb125a505086b00479444a5cc88d2968654b78cab0aff3c0eb9915e6bf68d5015788e3201a192c339e50826b505bfac804b909f0f9027ee370109bbbd9ff5bc4100457e02793ee1127fac46eb79bb265ca0fd1165e8a9a093135185072f18284b0eb0a4cfe60297371fed56a95814bc3852c0565c6cf18b8a331239711bb426f40b1b3a817445b141f8332d89cd17c33ca069117a2674244cbbfc0920f141af0947a55f2944eda67ab320805d51b468782c3efa90135ccbae85519ad15d0d4acddfe7742051589f5b9215a04a500c96a166a4b81298e3f0c347f6803616a4c1e85b1d322a640ba027470160ecc22cf176ed58b8d586b3ffe8a72b4957ab707d7181bff6a562dcea59de1b730aec958b1352107a6fc0479a136738a015a20e905f9219c7cd966470a0319e44981d5774a2f61b2cd75ff1c7b6630b8b9622cf93f7be159648725a680588ae4f96abfa911b7ac92238ab67688bc49e9530ace20ebcc70101409ceefca247a2c5db2313ef6569bfda215958822a0820af0b43bda5932a9025408299a3b99619c2a7acd097c1e701433c1f19c88fd7c20d3ea254121ba21ab553a2aa86b6835097cbae5f8158e8d00990aa5c28d695b910c6dbba814b664af80a2b5c72af80760927f92616832c06b9be170494410b8d39575613392749c8988404cbf11bbd5c222e1d146769fa8ab463c875e03061359873784aef6094bebab7b81b55a5009b1a5189a8802857511e9c14214c7059e3c7a1f80023bc3467b0ea7f7cc3aed217b2febb67be93294cd0a4aa96a16850408a84b79544acc2194ed3b8104395662d34b7c005981ea2636e24259e33bfc5c97f86a025cda2bd917bb375eaac5e10ab1911471325cda4c7662fe93cec756b330b6a8f74785d3028d20a70becca99d233e71555152db593e8c90555ba6dc9ba5e88764ee4890e4f05c0edb582e3c6737f9019685715a4579ebbace7a71a7eea788ef46970cd0a76414bd58e4383aca7ba73c198f82c1f6892506252bf7dc0084617619976329b41cc0d372074776f788364a853f93f22b1e885c38c65d51dc3c33a613c520b22a23590437351d46cbeeb7b8607589eff0061b1227a3624c610a54c8b55bbb0094810b1818ca198e09b7a72097c21686eba01e5df01ad61343c4f915b3ba8f69a819f2b7bf20fa2a2adc45a7a519f2485ee47cc57f2522d4794d2437916d2719cdc4418bd17646a1bc6979074371776eb31aacb1b66c234ac1b4c6dc395f61b28b435375bc7880a33814146820bce90300c8137a967a6a3a4437aa923d758402b0a4eb24777d09071a23209081361a9891f2b14052a80e2af7236525072c4055213bb4f1457a2d429b4eeb7111f05c36a72d0f072bfbf6156329905e793b014126b7a4393e46cb98953d416c991812804e2a151b4acc355573411523b8d37e5de7a686f30165d42e94d4b57ac995b78a4cbfcc0b7930186d566cc06b7f3ef2c3f6054f5d360df81c99981cb344d64a6a1ac338c27094700be2d8900f19195de225ff994f39ab1892aa74ebab884556cb1729079f3680e7d01018f47599d52baf7a0e768bacf955b44d0b22194a46d5b94f6543658cb132fac77375f00bd0a7463fc015a399705507525c566816fcc193980f762c0e8d533fc0279b0355ae7150b313001fea68322e9a0ce71154825599acf2cebf176a29c439e7dc4805a99108cb4f3715c7b07a36f932c149f4980f1902196c160c34a15fbb4354a906907bb57207b4323741e8bc75c57a40729156606bc71379aca718c23b9c40e0a97b56f708b6aa5c85a8bdfb67bcbbc75cb5b67fb8e6201ad598f8731719db5a135796ff4825fda74dc75bb6d0ca7b51dc682342b1df491664ea215cb322ab99c515f42f9e005115ec9b5ec49020242738ca8a4ba720fd0ac11703992ea0c0c1dbc18bf155bc2c141e0aacae21879880b37db038c101a6cae326314045cf76473181480f07474bd2b5811aa7142234ec6178b403b23147944795460865a0313306631bc01c8c797266bbfa0a3b660530e50041c1c0931121c393c48a26ea8444b78270ab20d0439843a07a31a2b74e5bcc69f528a0d5a5f6da1503d6b5c40c1ced87823ad52ab91697afc873bf64b9c88b88811921f4e782f6ca7a75c09879a40351e102c1ab292be7b163799125b3aa660ba1474141d4292d4cb065294448e72768c98bb00b2673ef2a1f9c400c7b09c718190ddce47db20221e91608919555993a60c2ab985ac61234805a0e8c8ae3601da8db9aad1232288570bb86a8f6f69c46c6ce3e91255afb660f8a2c99c5387e29b6a4b39c4b05753676bf555c876582111522bff9d5293e27093a6c7b73bb5ab9640eb2e76f5e961f46ccb7fb861f9de31cfe20820c23a3040c51e802819aa35e55b08bca35309530254f23829ed7ad77963ca7a69a659f55baafbfc5c49795c3d66d8bd8ade248fbacd722b6b19ed370ed53db0a907adeefe85b427a4fa68224bf4c7888fc36e23a8be7c07aa2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3";

    const KAT_CT_HEX: &str = "f3bec14d8dab6181e4ef72154b1de63a8fa22b59020bdfc7d05e0a0d739513f3d34e770a2f40f845cc5cf3f884a945c32a9ece4243505fc94464802a348e2ed6a8dedde4c0c329ec6193efdf0247557ed9f4d42bbf554104ab5f1393c93e3437de40577992a94369c8de101a88916746ac4901a17c695c8eb8c2a8716005c1b80e4fc231efa8b8b8174485827465a7cdd0912f1ba67435829852777e56ee507ff2bc187d9036afc041e23179a4560479d46ed5d4205f79af072ea5ecfa2280e71306c398202f306b5c4848e588485fb5fb67f057d0b2957959b0a065635cc25754621f4ccbde3f3380c6e63a226fb35f034a907d9eea0f4277d6ecae09fc349b79005a993d3272dccae38f54e9f43ef3351aec47c1da835019cdef21eeeeaca7859574367f3f7e075e94c14586d850b63b046611ab54c866e1ab5432248b7fbb8eba8149f124b5a09020045a1e7f3f7d1afeeea0a0d1bb641f937e0cad7bc7c5cb99ce481454768f548ab02f69f72d92115326c2978c6abbf28fc88249b3f5a9c28f17e061a5a85d676ae5474b55efa90042d1e50b749783e7a73c62ae513717d08a1074f2690e3435253ef85e153b3ceec995d2d27cbeff71c741acb9e800de74daa38dddf86646e299bd063f9bbce94356c1ecedf600f111139ec7b413b47653425deaf6f871a66f24fb11fa0495bab651f36d59fa9f10e523b0edcaf5b9d6fe1f1ebed903def1a0c9b15aa94ef48f7eedeb2244f719bb497d367d12b3c80131edaffb38f22afe8c35992304b0f2a2abe07953ed9b1a2bee9df628a76928ed42fece1f85bcee7cc820471596cae6cd60f8ffa7ca3d09d850037c8424a3dc2511ef557af01b0db551a078300367957e21a822b926c72e68f766494dd24c9910ac6221ff6485fa5f200098d4db17fbabdd71e950da8c81c083f98f2995540041b91d7adb2e67e40f412a5bd90f81d0979cc057d3efde4cec6c4b31b6fc10c00f678fa0673e4efacbda2f4e26406836f4000206c0545003dbec953344a12899389430601b710f159432de0be03882b69b32be0a47334dc773883ff272c6c5423a26484eeb49f312d0f14d89917b23d86fa60185463ecaa4ef158b52d77375ec5e4c5b919da542fcf46e0d1f8a71c3c31ac5b3e9b93ee8901eecac0c81e3a953bbcc5054b96468f715f1a587b38853798b5dde98becad800007b0e25f67cbed47c596fb189d9914426f7da8c4bbf140c576694846b34c41146d52a3a4fe57043283f7276212e089bb156c4256f78ab847b7fa8385579ce1f3158dc22383db51dadba0a527b637595349032db82f050cf94e5839d723b0078ee9486f02589ecfaa14bbcd489b83ce7264d42d9ea1ebfcc59e5a4241c3e15ee2244b40205cfb27cd73321effbaa84bc820031c715fe16b571de979a6d29ccfd52c3d8c04c0af5a91c4fd6e10f4635cedbc950610e8fa9fcfe7c14a36f85e76b7aa85de3beb4f88a32ec639bfd61099de8ce163123a3e89da7eecb3ee26a3d10b8fb67d32b83d402c65fef13fc76023a9ee6ded987b6aa93958cdc2097ef9fc845d5319c9ca100d35e";

    #[test]
    fn test_encaps_decaps() {
        // Generate key pair
        let keypair = HybridKeyPair::generate().expect("keygen should succeed");

        // Encapsulate
        let encaps_result = keypair.ek.encaps().expect("encaps should succeed");

        // Decapsulate
        let shared_secret = keypair
            .dk
            .decaps(&encaps_result.ciphertext)
            .expect("decaps should succeed");

        // Verify shared secrets match
        assert_eq!(
            encaps_result.shared_secret.as_bytes(),
            shared_secret.as_bytes()
        );
    }

    #[test]
    fn test_key_roundtrip() {
        let keypair = HybridKeyPair::generate().expect("keygen should succeed");

        // Export and reimport encaps key
        let ek_bytes = keypair.ek.as_bytes();
        let ek2 = HybridEncapsKey::from_bytes(ek_bytes);

        // Encaps with reimported key should work
        let result = ek2.encaps().expect("encaps should succeed");
        let ss = keypair.dk.decaps(&result.ciphertext).expect("decaps should succeed");
        assert_eq!(result.shared_secret.as_bytes(), ss.as_bytes());
    }

    #[test]
    fn test_ciphertext_size() {
        let keypair = HybridKeyPair::generate().expect("keygen should succeed");
        let result = keypair.ek.encaps().expect("encaps should succeed");

        // Hybrid ciphertext = ML-KEM ciphertext (1088) + X25519 public key (32) = 1120
        assert_eq!(result.ciphertext.as_bytes().len(), QV_HYBRID_CT_SIZE);
        assert_eq!(QV_HYBRID_CT_SIZE, 1120);
    }
}
