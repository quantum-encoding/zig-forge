# Event Ticket System

Multi-layer steganographic ticketing system for events, conferences, concerts, and access control.

## Concept

Traditional ticketing systems create individual QR codes or barcodes for each attendee. This system takes a different approach:

- **One image holds up to 256 unique tickets** (one per steganographic layer)
- **Each attendee gets a unique password** (their access key)
- **The image can be shared publicly** (on social media, websites, emails)
- **Only password holders can extract their ticket** (cryptographically secured)

This is ideal for:
- Concert tickets embedded in promotional artwork
- Conference passes hidden in event logos
- VIP access credentials in branded images
- Access tokens in NFT artwork

## CLI Usage

### Create Tickets

```bash
# Create 100 tickets for a concert
zsss ticket create \
  --image artwork.png \
  --event "CONCERT-2026" \
  --count 100 \
  --tier VIP \
  --seat-prefix "A-" \
  --output tickets

# Output:
#   tickets.png         - Image with embedded tickets
#   tickets_passwords.txt - Password list for distribution
```

### Verify a Ticket

```bash
# Attendee verifies their ticket
zsss ticket verify \
  --image tickets.png \
  --password "Kb3NJgWf"

# Output:
#   VALID TICKET
#     Event: CONCERT-2026
#     Ticket ID: 095b14de93650b5e918818ffcfb2a9d6
#     Layer: 0
#     Seat: A-1
#     Tier: VIP
```

### Get Ticket Information

```bash
# Get detailed ticket info
zsss ticket info \
  --image tickets.png \
  --password "Kb3NJgWf"
```

### Check Image Capacity

```bash
# See how many tickets an image can hold
zsss ticket capacity --image artwork.png

# Output:
#   Image Ticket Capacity
#   =====================
#   Dimensions:      1024 x 1024
#   Total pixels:    1048576
#   Pixels/layer:    4096
#   Bytes/layer:     475
#   Max layers:      256
#   Practical capacity: 256 tickets
```

## C API Usage

```c
#include "zsss.h"
#include <stdio.h>

int main() {
    zsss_init();

    // Load PNG image
    FILE* f = fopen("artwork.png", "rb");
    fseek(f, 0, SEEK_END);
    size_t png_len = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t* png = malloc(png_len);
    fread(png, 1, png_len, f);
    fclose(f);

    // Check capacity
    size_t bytes_per_ticket;
    int32_t max_tickets = zsss_ticket_capacity(png, png_len, &bytes_per_ticket);
    printf("Can hold %d tickets, %zu bytes each\n", max_tickets, bytes_per_ticket);

    // Create a ticket
    ZsssBuffer result = zsss_ticket_embed(
        png, png_len,
        (uint8_t*)"CONCERT-2026", 12,
        (uint8_t*)"SecretPass123", 13,
        0,  // layer
        (uint8_t*)"A-1", 3,   // seat
        (uint8_t*)"VIP", 3    // tier
    );

    if (result.error_code == ZSSS_OK) {
        // Save new PNG with embedded ticket
        FILE* out = fopen("ticket_image.png", "wb");
        fwrite(result.data, 1, result.len, out);
        fclose(out);
        zsss_free(result);
    }

    // Verify a ticket
    ZsssTicketInfo info;
    int32_t err = zsss_ticket_info(
        png, png_len,
        (uint8_t*)"SecretPass123", 13,
        &info
    );

    if (err == ZSSS_OK) {
        printf("Event: %.*s\n", (int)info.event_id_len, info.event_id);
        printf("Seat: %.*s\n", (int)info.seat_len, info.seat);
        printf("Tier: %.*s\n", (int)info.tier_len, info.tier);
        zsss_ticket_info_free(&info);
    } else {
        printf("Invalid ticket: %s\n", zsss_error_message(err));
    }

    free(png);
    return 0;
}
```

## How It Works

### Multi-Layer Steganography

The image uses LSB (Least Significant Bit) steganography with 256 virtual layers:

1. Each pixel is assigned to a layer based on its position: `layer = pixel_index % 256`
2. Tickets are embedded in their assigned layer's pixels only
3. Different passwords decrypt different layers
4. Layers are independent - one ticket cannot interfere with another

### Security

- **ChaCha20-Poly1305 encryption** protects each ticket with its password
- **Password-derived keys** using Argon2-like stretching
- **No detectable pattern** - steganographic data is indistinguishable from image noise
- **One-time passwords** - each password unlocks exactly one ticket

### Ticket Format

Each ticket contains:
- Event ID (required)
- Unique ticket ID (auto-generated)
- Seat assignment (optional)
- Tier/class (optional)
- Issue timestamp
- Expiration timestamp (optional)
- Cryptographic signature

## Image Requirements

| Image Size | Pixels | Bytes/Layer | Usable Capacity |
|------------|--------|-------------|-----------------|
| 256x256    | 65,536 | 30 bytes    | Basic tickets |
| 512x512    | 262,144 | 118 bytes  | Standard tickets |
| 1024x1024  | 1,048,576 | 475 bytes | Full metadata |
| 2048x2048  | 4,194,304 | 1.8 KB   | Extended data |

## Use Cases

### Concert Tickets
```bash
# Organizer creates tickets
zsss ticket create --image band_poster.png --event "ROCK-FEST-2026" -c 500 --tier General -o concert

# Distribute passwords via email, SMS, or app
# Attendees verify at venue
zsss ticket verify --image band_poster.png --password "AttendeePass"
```

### Conference Access
```bash
# Different tiers for different access levels
zsss ticket create --image logo.png --event "TECH-CONF" -c 50 --tier VIP --seat-prefix "VIP-" -o vip_tickets
zsss ticket create --image logo.png --event "TECH-CONF" -c 200 --tier General -o general_tickets
```

### NFT Utility
```bash
# Embed utility in NFT artwork
# Buyer gets image + password
# Password unlocks exclusive content/access
zsss ticket create --image nft_art.png --event "NFT-ACCESS" -c 1 --tier Owner -o nft_utility
```

## Error Codes

| Code | Name | Description |
|------|------|-------------|
| 0 | ZSSS_OK | Success |
| -16 | ZSSS_ERR_TICKET_NOT_FOUND | No ticket found for password |
| -17 | ZSSS_ERR_TICKET_EXPIRED | Ticket has expired |
| -18 | ZSSS_ERR_TICKET_INVALID | Invalid ticket data |
| -19 | ZSSS_ERR_LAYER_OCCUPIED | Layer already has data |
| -11 | ZSSS_ERR_IMAGE_TOO_SMALL | Image cannot hold ticket data |

## Best Practices

1. **Use high-resolution images** - More pixels = more capacity per ticket
2. **Use PNG format** - Lossless compression preserves hidden data
3. **Avoid JPEG** - Lossy compression destroys steganographic data
4. **Secure password distribution** - Send passwords through secure channels
5. **Keep password list secure** - The password file is the master key
6. **Use expiration dates** - For time-limited access
