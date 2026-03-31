# NFT Photo Signing Integration for Quantum Vault

## Concept Overview

**The image IS the asset.** Unlike traditional NFTs where the image is just a pointer to blockchain metadata, this approach embeds cryptographic ownership directly INTO the image pixels using LSB steganography.

### Why This Creates Real Value

1. **Bearer Instrument** - Whoever possesses the image AND knows the password controls the asset
2. **Self-Contained** - No dependency on external blockchain indexers or IPFS gateways
3. **Transferable** - Send the image file + password = transfer ownership
4. **Verifiable** - Anyone with the public password can verify authenticity
5. **Private** - Hidden data is indistinguishable from normal image noise

## Architecture: Two-Layer System

```
┌─────────────────────────────────────────────────────────┐
│                    SIGNED IMAGE                          │
│  ┌─────────────────────────────────────────────────────┐│
│  │              Original Photo Pixels                   ││
│  │                                                      ││
│  │   ┌─────────────────┐   ┌─────────────────┐         ││
│  │   │   LAYER 0       │   │   LAYER 1       │         ││
│  │   │   (Public)      │   │   (Private)     │         ││
│  │   │                 │   │                 │         ││
│  │   │ • Certificate   │   │ • Private Key   │         ││
│  │   │ • Artist ID     │   │ • Ownership     │         ││
│  │   │ • Creation Date │   │ • Transfer Key  │         ││
│  │   │ • Edition #     │   │ • Event Trigger │         ││
│  │   │                 │   │                 │         ││
│  │   │ Password:       │   │ Password:       │         ││
│  │   │ "verify"        │   │ [buyer_secret]  │         ││
│  │   └─────────────────┘   └─────────────────┘         ││
│  │                                                      ││
│  └─────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────┘
```

### Layer 0: Public Certificate (Verifiable by Anyone)
- **Password**: Known/published (e.g., "verify", artist name, or derived from image hash)
- **Contains**:
  ```json
  {
    "artist": "0xABCD...",
    "created": "2026-01-08T12:00:00Z",
    "edition": "1/100",
    "collection": "Quantum Dreams",
    "signature": "<artist_signature_of_image_hash>"
  }
  ```
- **Purpose**: Proves authenticity, origin, and edition number

### Layer 1: Private Ownership (Secret to Owner)
- **Password**: Known only to current owner
- **Contains**:
  ```
  OWNERSHIP_KEY=0x1234567890ABCDEF...
  EVENT_TRIGGER=https://api.example.com/nft/transfer
  TRANSFER_SECRET=<one_time_transfer_code>
  ```
- **Purpose**: Proves ownership, enables transfers, triggers blockchain events

## User Flow in Quantum Vault App

### 1. CREATE/SIGN Flow
```
User selects photo from:
  ├── Camera roll
  ├── Photo library
  └── Direct upload to app cache

         ↓

App presents signing form:
  ├── Artist/Creator name
  ├── Collection name (optional)
  ├── Edition number (e.g., "1 of 10")
  ├── Description/metadata
  └── Public verification password

         ↓

App generates:
  ├── Unique ownership key (cryptographic random)
  ├── Private password (user-chosen or generated)
  └── Event trigger URL (if blockchain integration)

         ↓

App embeds via zsss:
  1. Layer 0: Public certificate (JSON)
  2. Layer 1: Private ownership data

         ↓

Export options:
  ├── Save to Photos (new name: "original_SIGNED.png")
  ├── Share directly
  └── Upload to marketplace
```

### 2. VERIFY Flow (Anyone)
```
User imports signed image
         ↓
App prompts for verification password
(or uses known public password)
         ↓
App extracts Layer 0 certificate
         ↓
Displays:
  ├── ✓ Authentic signature verified
  ├── Artist: @artist_name
  ├── Created: 2026-01-08
  ├── Edition: 3/100
  └── Collection: "Quantum Dreams"
```

### 3. PROVE OWNERSHIP Flow (Owner Only)
```
User imports their signed image
         ↓
App prompts for PRIVATE password
         ↓
App extracts Layer 1 ownership data
         ↓
Options:
  ├── View ownership key
  ├── Generate ownership proof
  ├── Initiate transfer
  └── Trigger blockchain event
```

### 4. TRANSFER Flow
```
Seller has signed image + private password
         ↓
Seller initiates transfer in app:
  1. Enter current private password
  2. App verifies ownership
  3. App generates NEW ownership layer
  4. Buyer provides NEW private password
         ↓
App creates new image with:
  - Layer 0: Same public certificate
  - Layer 1: NEW ownership (new password, new key)
         ↓
Buyer receives:
  - New image file (pixels slightly different)
  - New private password
         ↓
Seller's old image now has INVALID Layer 1
(ownership transferred to new key)
```

## Integration Code Examples

### Android/iOS Integration (via JNI/FFI)

```kotlin
// Kotlin/Android example
class NftSigner(private val zsssLib: ZsssLibrary) {

    fun signPhoto(
        imageBytes: ByteArray,
        certificate: NftCertificate,
        publicPassword: String,
        ownershipKey: ByteArray,
        privatePassword: String
    ): ByteArray {
        // Initialize library
        zsssLib.zsss_init()

        // Embed Layer 0 (public certificate)
        val withLayer0 = zsssLib.zsss_stego_embed(
            imageBytes,
            certificate.toJson().toByteArray(),
            publicPassword.toByteArray(),
            layerSlot = 0
        )

        // Embed Layer 1 (private ownership)
        val withBothLayers = zsssLib.zsss_stego_embed(
            withLayer0,
            ownershipKey,
            privatePassword.toByteArray(),
            layerSlot = 1
        )

        return withBothLayers
    }

    fun verifyCertificate(
        imageBytes: ByteArray,
        publicPassword: String
    ): NftCertificate? {
        val result = zsssLib.zsss_stego_extract(
            imageBytes,
            publicPassword.toByteArray(),
            layerSlot = 0
        )

        return if (result.errorCode == 0) {
            NftCertificate.fromJson(String(result.data))
        } else null
    }

    fun proveOwnership(
        imageBytes: ByteArray,
        privatePassword: String
    ): OwnershipProof? {
        val result = zsssLib.zsss_stego_extract(
            imageBytes,
            privatePassword.toByteArray(),
            layerSlot = 1
        )

        return if (result.errorCode == 0) {
            OwnershipProof(result.data)
        } else null
    }
}
```

### Swift/iOS Example

```swift
class NFTSigner {
    func signPhoto(
        image: UIImage,
        certificate: NFTCertificate,
        publicPassword: String,
        privatePassword: String
    ) -> UIImage? {
        guard let pngData = image.pngData() else { return nil }

        // Generate ownership key
        var ownershipKey = [UInt8](repeating: 0, count: 32)
        SecRandomCopyBytes(kSecRandomDefault, 32, &ownershipKey)

        // Embed public layer
        var layer0Result = zsss_stego_embed(
            pngData.bytes, pngData.count,
            certificate.jsonData.bytes, certificate.jsonData.count,
            publicPassword.utf8, publicPassword.utf8.count,
            0  // Layer 0
        )
        defer { zsss_free(layer0Result) }

        guard layer0Result.error_code == 0 else { return nil }

        // Embed private layer
        let layer0Data = Data(bytes: layer0Result.data!, count: layer0Result.len)
        var layer1Result = zsss_stego_embed(
            layer0Data.bytes, layer0Data.count,
            ownershipKey, 32,
            privatePassword.utf8, privatePassword.utf8.count,
            1  // Layer 1
        )
        defer { zsss_free(layer1Result) }

        guard layer1Result.error_code == 0 else { return nil }

        let signedData = Data(bytes: layer1Result.data!, count: layer1Result.len)
        return UIImage(data: signedData)
    }
}
```

## File Naming Convention

When exporting signed images:

```
Original: vacation_photo.jpg
Signed:   vacation_photo_SIGNED_20260108.png

Original: artwork.png
Signed:   artwork_NFT_1of100.png

Original: IMG_4521.jpg
Signed:   IMG_4521_QUANTUM_SIGNED.png
```

**Important**: Always export as PNG (lossless) to preserve embedded data.

## Security Considerations

1. **Password Strength**: Private passwords should be strong (recommend 16+ chars or passphrase)

2. **Key Derivation**: Passwords are processed through HKDF-SHA256 before use

3. **Encryption**: All embedded data is encrypted with AES-256-GCM

4. **Position Scrambling**: Bit positions are scrambled using password-seeded Fisher-Yates shuffle

5. **Layer Isolation**: Each layer uses only every 256th pixel (no collision between layers)

6. **MSB Seeding**: Position scrambling uses only top 7 bits of pixels (immune to LSB modifications)

## Blockchain Integration (Optional)

The private layer can store:

```json
{
  "ownership_key": "0x...",
  "chain_id": 1,
  "contract": "0x...",
  "token_id": 12345,
  "event_endpoint": "https://api.nft.com/trigger",
  "transfer_signature": "<signed_message>"
}
```

When ownership is proven, the app can:
1. Call the event endpoint with signed proof
2. Trigger on-chain transfer
3. Update marketplace listings
4. Record provenance

## Library Location

The zsss library with multi-layer steganography support is at:
```
quantum-zig-forge/programs/zig_core_utils/zsss/
├── src/
│   ├── lib.zig          # FFI exports
│   ├── stego.zig        # Steganography engine
│   └── main.zig         # CLI tool
├── include/
│   └── zsss.h           # C header for FFI
└── zig-out/lib/
    ├── libzsss-aarch64-android.so
    ├── libzsss-aarch64-ios.a
    ├── libzsss-aarch64-macos.dylib
    └── ... (all platforms)
```

## CLI Testing

```bash
# Sign a photo with two layers
zsss stego embed --image photo.png -i certificate.json -o signed.png -l 0 -p "verify"
zsss stego embed --image signed.png -i ownership.key -o signed.png -l 1 -p "secret123"

# Verify certificate (anyone)
zsss stego extract --image signed.png -o cert.json -l 0 -p "verify"

# Prove ownership (owner only)
zsss stego extract --image signed.png -o owner.key -l 1 -p "secret123"
```

## Summary

This system creates **real digital ownership** because:

1. **Possession matters** - The image file contains the actual ownership key
2. **Knowledge matters** - Only the password holder can access ownership
3. **Cryptographic proof** - AES-256-GCM ensures integrity
4. **Self-sovereign** - No external dependencies required
5. **Transferable** - New owner gets new image with new ownership layer

The photo becomes a **bearer instrument** - like a physical deed or certificate, but cryptographically secured and hidden in plain sight.
