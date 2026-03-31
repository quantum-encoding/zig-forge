// SYNAPSE BRIDGE IMPLEMENTATION
// The actual ring buffer code that both Go and Zig will use

#include "synapse_bridge.h"
#include <stdlib.h>
#include <string.h>

RingBuffer* synapse_create_ring(size_t requested_size) {
    // Ensure power of 2
    size_t actual_size = 1;
    while (actual_size < requested_size) {
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

void synapse_destroy_ring(RingBuffer* ring) {
    if (!ring) return;
    if (ring->buffer) free(ring->buffer);
    free(ring);
}

int synapse_write_packet(RingBuffer* ring, const MarketPacket* packet) {
    if (!ring || !packet) return 0;
    
    const size_t packet_size = sizeof(MarketPacket);
    
    size_t producer = atomic_load_explicit(&ring->producer_head, memory_order_relaxed);
    size_t consumer = atomic_load_explicit(&ring->consumer_head, memory_order_acquire);
    
    // Check if full
    if ((producer - consumer) * packet_size >= ring->size) {
        return 0;
    }
    
    size_t index = (producer * packet_size) & ring->mask;
    memcpy(ring->buffer + index, packet, packet_size);
    
    atomic_store_explicit(&ring->producer_head, producer + 1, memory_order_release);
    return 1;
}

int synapse_read_packet(RingBuffer* ring, MarketPacket* packet) {
    if (!ring || !packet) return 0;
    
    const size_t packet_size = sizeof(MarketPacket);
    
    size_t consumer = atomic_load_explicit(&ring->consumer_head, memory_order_relaxed);
    size_t producer = atomic_load_explicit(&ring->producer_head, memory_order_acquire);
    
    // Check if empty
    if (consumer >= producer) {
        return 0;
    }
    
    size_t index = (consumer * packet_size) & ring->mask;
    memcpy(packet, ring->buffer + index, packet_size);
    
    atomic_store_explicit(&ring->consumer_head, consumer + 1, memory_order_release);
    return 1;
}

int synapse_write_order(RingBuffer* ring, const Order* order) {
    if (!ring || !order) return 0;
    
    const size_t order_size = sizeof(Order);
    
    size_t producer = atomic_load_explicit(&ring->producer_head, memory_order_relaxed);
    size_t consumer = atomic_load_explicit(&ring->consumer_head, memory_order_acquire);
    
    if ((producer - consumer) * order_size >= ring->size) {
        return 0;
    }
    
    size_t index = (producer * order_size) & ring->mask;
    memcpy(ring->buffer + index, order, order_size);
    
    atomic_store_explicit(&ring->producer_head, producer + 1, memory_order_release);
    return 1;
}

int synapse_read_order(RingBuffer* ring, Order* order) {
    if (!ring || !order) return 0;
    
    const size_t order_size = sizeof(Order);
    
    size_t consumer = atomic_load_explicit(&ring->consumer_head, memory_order_relaxed);
    size_t producer = atomic_load_explicit(&ring->producer_head, memory_order_acquire);
    
    if (consumer >= producer) {
        return 0;
    }
    
    size_t index = (consumer * order_size) & ring->mask;
    memcpy(order, ring->buffer + index, order_size);
    
    atomic_store_explicit(&ring->consumer_head, consumer + 1, memory_order_release);
    return 1;
}