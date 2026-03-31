#!/usr/bin/env python3
"""
RECONNAISSANCE: Capture the Perfect WebSocket Handshake
Objective: Determine exact headers and protocol requirements for Alpaca WebSocket
"""

import os
import websocket
import json
import time
import logging

# Enable debug logging to capture handshake details
logging.basicConfig(level=logging.DEBUG)

def on_message(ws, message):
    print(f"📨 RECEIVED: {message}")

def on_error(ws, error):
    print(f"❌ ERROR: {error}")

def on_close(ws, close_status_code, close_msg):
    print(f"🔌 CLOSED: {close_status_code} - {close_msg}")

def on_open(ws):
    print("✅ WebSocket OPENED - Connection Successful!")
    
    # Get credentials
    api_key = os.environ.get('APCA_API_KEY_ID')
    api_secret = os.environ.get('APCA_API_SECRET_KEY')
    
    if not api_key or not api_secret:
        print("❌ Missing credentials")
        return
    
    # Send authentication - this is the critical message
    auth_msg = json.dumps({
        "action": "auth",
        "key": api_key,
        "secret": api_secret
    })
    
    print(f"📤 SENDING AUTH: {auth_msg}")
    ws.send(auth_msg)
    
    # Wait a bit for auth response
    time.sleep(2)
    
    # Send subscription
    sub_msg = json.dumps({
        "action": "subscribe",
        "quotes": ["SPY"],
        "trades": ["SPY"]
    })
    
    print(f"📤 SENDING SUB: {sub_msg}")
    ws.send(sub_msg)

def main():
    print("\n" + "="*60)
    print("🕵️  RECONNAISSANCE: Alpaca WebSocket Handshake Analysis")
    print("="*60)
    
    # Different endpoint options to test
    endpoints = [
        "wss://paper-api.alpaca.markets/stream",
        "wss://stream.data.alpaca.markets/v2/iex",
        "wss://stream.data.alpaca.markets/v2/sip"
    ]
    
    for endpoint in endpoints:
        print(f"\n🎯 TESTING ENDPOINT: {endpoint}")
        print("-" * 50)
        
        try:
            # Create WebSocket with debug enabled
            websocket.enableTrace(True)
            ws = websocket.WebSocketApp(
                endpoint,
                on_open=on_open,
                on_message=on_message,
                on_error=on_error,
                on_close=on_close,
                header={
                    "User-Agent": "QuantumSynapseEngine/1.0",
                    "Origin": "https://alpaca.markets"
                }
            )
            
            # Run for 10 seconds
            ws.run_forever()
            
        except Exception as e:
            print(f"❌ ENDPOINT FAILED: {e}")
        
        print(f"✅ ENDPOINT TEST COMPLETE: {endpoint}")
        print("-" * 50)
        
        # Small delay between tests
        time.sleep(2)
    
    print("\n🔍 RECONNAISSANCE COMPLETE")

if __name__ == "__main__":
    main()