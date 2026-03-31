// RING BUFFER IMPLEMENTATION - The Synaptic Cleft
// Lock-free SPSC ring buffer for Go-Zig communication
// Reused from the Nuclear Fire Hose with pride

#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

// Ring buffer structure
typedef struct {
    uint8_t* buffer;
    size_t size;
    size_t mask;
    _Atomic size_t producer_head;
    _Atomic size_t consumer_head;
    char padding[64]; // Cache line padding
} RingBuffer;

// Create a new ring buffer
void* create_ring_buffer(size_t size) {
    // Ensure size is power of 2
    size_t actual_size = 1;
    while (actual_size < size) {
        actual_size <<= 1;
    }
    
    RingBuffer* ring = (RingBuffer*)calloc(1, sizeof(RingBuffer));
    if (!ring) return NULL;
    
    ring->buffer = (uint8_t*)calloc(actual_size, 1);
    if (!ring->buffer) {
        free(ring);
        return NULL;
    }
    
    ring->size = actual_size;
    ring->mask = actual_size - 1;
    atomic_store(&ring->producer_head, 0);
    atomic_store(&ring->consumer_head, 0);
    
    return ring;
}

// Destroy ring buffer
void destroy_ring_buffer(void* ring_ptr) {
    if (!ring_ptr) return;
    
    RingBuffer* ring = (RingBuffer*)ring_ptr;
    if (ring->buffer) {
        free(ring->buffer);
    }
    free(ring);
}

// Write a market packet to the ring (Go -> Zig)
int write_market_packet(void* ring_ptr, void* packet) {
    RingBuffer* ring = (RingBuffer*)ring_ptr;
    if (!ring || !packet) return 0;
    
    const size_t packet_size = 64; // MarketPacket is 64 bytes
    
    size_t producer = atomic_load_explicit(&ring->producer_head, memory_order_relaxed);
    size_t consumer = atomic_load_explicit(&ring->consumer_head, memory_order_acquire);
    
    // Check if ring is full
    if (producer - consumer >= ring->size / packet_size) {
        return 0; // Ring full
    }
    
    // Calculate index and write packet
    size_t index = (producer * packet_size) & ring->mask;
    memcpy(ring->buffer + index, packet, packet_size);
    
    // Update producer head
    atomic_store_explicit(&ring->producer_head, producer + 1, memory_order_release);
    
    return 1; // Success
}

// Read an order from the ring (Zig -> Go)
int read_order(void* ring_ptr, void* order) {
    RingBuffer* ring = (RingBuffer*)ring_ptr;
    if (!ring || !order) return 0;
    
    const size_t order_size = 40; // Order is 40 bytes
    
    size_t consumer = atomic_load_explicit(&ring->consumer_head, memory_order_relaxed);
    size_t producer = atomic_load_explicit(&ring->producer_head, memory_order_acquire);
    
    // Check if ring is empty
    if (consumer >= producer) {
        return 0; // Ring empty
    }
    
    // Calculate index and read order
    size_t index = (consumer * order_size) & ring->mask;
    memcpy(order, ring->buffer + index, order_size);
    
    // Update consumer head
    atomic_store_explicit(&ring->consumer_head, consumer + 1, memory_order_release);
    
    return 1; // Success
}

// Get ring buffer stats (for debugging)
void get_ring_stats(void* ring_ptr, size_t* producer, size_t* consumer, size_t* size) {
    RingBuffer* ring = (RingBuffer*)ring_ptr;
    if (!ring) return;
    
    *producer = atomic_load(&ring->producer_head);
    *consumer = atomic_load(&ring->consumer_head);
    *size = ring->size;
}