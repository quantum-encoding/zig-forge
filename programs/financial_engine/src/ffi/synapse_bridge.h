// SYNAPSE BRIDGE - The Canonical Truth
// This header defines the EXACT memory layout for Go-Zig communication
// Both languages MUST use these definitions

#ifndef SYNAPSE_BRIDGE_H
#define SYNAPSE_BRIDGE_H

#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>

// ============================================================================
// CANONICAL STRUCT DEFINITIONS
// ============================================================================

// MarketPacket - 64 bytes exactly
typedef struct __attribute__((packed)) {
    uint64_t timestamp_ns;
    uint32_t symbol_id;
    uint8_t  packet_type;  // 0=quote, 1=trade
    uint8_t  flags;
    uint64_t price_field;  // Fixed point: multiply float by 1,000,000
    uint32_t qty_field;    // Quantity
    uint32_t order_id_field;
    uint8_t  side_field;   // 0=bid, 1=ask, 2=trade
    uint8_t  _padding[23];
} MarketPacket;

// Order - 40 bytes exactly
typedef struct __attribute__((packed)) {
    uint32_t symbol_id;
    uint8_t  side_field;   // 0=buy, 1=sell
    uint64_t price_field;  // Fixed point
    uint32_t qty_field;
    uint64_t timestamp_ns;
    uint8_t  strategy_id;
    uint8_t  _padding[7];
} Order;

// Ring buffer structure
typedef struct {
    uint8_t* buffer;
    size_t size;
    size_t mask;
    _Atomic size_t producer_head;
    _Atomic size_t consumer_head;
    char cache_padding[64];
} RingBuffer;

// ============================================================================
// RING BUFFER FUNCTIONS
// ============================================================================

// Create a power-of-2 sized ring buffer
RingBuffer* synapse_create_ring(size_t size);

// Destroy ring buffer
void synapse_destroy_ring(RingBuffer* ring);

// Write a MarketPacket to the ring (Go -> Zig)
int synapse_write_packet(RingBuffer* ring, const MarketPacket* packet);

// Read a MarketPacket from the ring (Zig <- Go)
int synapse_read_packet(RingBuffer* ring, MarketPacket* packet);

// Write an Order to the ring (Zig -> Go)
int synapse_write_order(RingBuffer* ring, const Order* order);

// Read an Order from the ring (Go <- Zig)
int synapse_read_order(RingBuffer* ring, Order* order);

#endif // SYNAPSE_BRIDGE_H