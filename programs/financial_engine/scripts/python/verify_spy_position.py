#!/usr/bin/env python3
"""
PHASE 3: THE CONFIRMATION
External verification of SPY trade execution via Alpaca API query
"""

import os
import alpaca_trade_api as tradeapi
from datetime import datetime

def main():
    print("\n" + "="*60)
    print("🔍 PHASE 3: THE CONFIRMATION")
    print("   External Verification of SPY Trade Execution")
    print("="*60)
    
    # Get credentials from environment
    api_key = os.environ.get('APCA_API_KEY_ID')
    api_secret = os.environ.get('APCA_API_SECRET_KEY')
    
    if not api_key or not api_secret:
        print("❌ ERROR: Alpaca API credentials not found in environment")
        print("   Please set APCA_API_KEY_ID and APCA_API_SECRET_KEY")
        return 1
    
    print(f"✅ API Key: {api_key[:8]}...")
    print(f"✅ Secret: {api_secret[:8]}...")
    
    # Initialize Alpaca API client (paper trading)
    api = tradeapi.REST(
        api_key,
        api_secret,
        base_url='https://paper-api.alpaca.markets'
    )
    
    try:
        # Get account info
        account = api.get_account()
        print(f"\n📊 ACCOUNT STATUS:")
        print(f"   Account ID: {account.id}")
        print(f"   Status: {account.status}")
        print(f"   Buying Power: ${float(account.buying_power):,.2f}")
        print(f"   Cash: ${float(account.cash):,.2f}")
        
        # Get all positions
        positions = api.list_positions()
        print(f"\n📈 CURRENT POSITIONS:")
        
        if not positions:
            print("   No positions found")
        else:
            for pos in positions:
                print(f"   {pos.symbol}: {pos.qty} shares @ ${float(pos.market_value):,.2f}")
        
        # Check specifically for SPY position
        spy_position = None
        for pos in positions:
            if pos.symbol == 'SPY':
                spy_position = pos
                break
        
        if spy_position:
            print(f"\n🎯 SPY POSITION CONFIRMED:")
            print(f"   Symbol: {spy_position.symbol}")
            print(f"   Quantity: {spy_position.qty}")
            print(f"   Market Value: ${float(spy_position.market_value):,.2f}")
            print(f"   Average Entry Price: ${float(spy_position.avg_entry_price):,.2f}")
            print(f"   Unrealized P&L: ${float(spy_position.unrealized_pl):,.2f}")
            print(f"\n🔥 MISSION ACCOMPLISHED: SPY POSITION VERIFIED! 🔥")
            return 0
        else:
            print(f"\n⚠️  SPY POSITION NOT FOUND")
            print("   This could mean:")
            print("   1. Order was placed but not yet filled")
            print("   2. Order was rejected by broker")
            print("   3. Simulated order system used")
            
        # Get recent orders to check order status
        print(f"\n📋 RECENT ORDERS:")
        orders = api.list_orders(status='all', limit=10)
        
        if not orders:
            print("   No recent orders found")
        else:
            for order in orders:
                print(f"   {order.symbol}: {order.side} {order.qty} @ {order.order_type} - Status: {order.status}")
                if order.symbol == 'SPY':
                    print(f"      🎯 SPY ORDER FOUND: {order.status}")
        
        return 0
        
    except Exception as e:
        print(f"❌ API ERROR: {e}")
        return 1

if __name__ == "__main__":
    exit(main())