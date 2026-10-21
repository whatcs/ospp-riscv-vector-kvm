#!/usr/bin/env python3
"""Send one command to the selected lab QMP Unix socket."""
import json
import socket
import sys

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
    conn.settimeout(10)
    conn.connect(sys.argv[1])
    stream = conn.makefile("rwb")
    print(stream.readline().decode().strip())
    for number, command in enumerate(("qmp_capabilities", sys.argv[2])):
        stream.write((json.dumps({"execute": command, "id": number}) + "\n").encode())
        stream.flush()
        while True:
            line = stream.readline()
            if not line:
                raise SystemExit("QMP closed before replying")
            reply = json.loads(line)
            print(json.dumps(reply))
            if reply.get("id") == number:
                if "error" in reply:
                    raise SystemExit(1)
                break
