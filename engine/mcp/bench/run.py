#!/usr/bin/env python3
"""Run the fixed stdio and HTTP workloads against one provider binary."""

from pathlib import Path
import re
import socket
import subprocess
import sys
import time


def measure(binary, endpoint):
    return subprocess.run([binary, 'measure', endpoint], check=True, timeout=3_910,
                          capture_output=True, text=True).stdout


def run(binary):
    stdio = measure(binary, binary)
    print(f'stdio {stdio.strip()}', flush=True)
    with socket.socket() as allocator:
        allocator.bind(('127.0.0.1', 0))
        port = allocator.getsockname()[1]
    with subprocess.Popen([binary, 'http', str(port)]) as server:
        try:
            for _ in range(200):
                try:
                    socket.create_connection(('127.0.0.1', port), timeout=0.1).close()
                    break
                except OSError:
                    if server.poll() is not None:
                        raise RuntimeError(f'HTTP server failed: {server.returncode}')
                    time.sleep(0.01)
            else:
                raise RuntimeError('HTTP server did not open')
            http = measure(binary, f'http://127.0.0.1:{port}/mcp')
            print(f'http {http.strip()}', flush=True)
        finally:
            server.terminate()
            server.wait(timeout=5)
    assert re.search(r'checksum=(\d+)', stdio)[1] == re.search(r'checksum=(\d+)', http)[1]


if __name__ == '__main__':
    run(str(Path(sys.argv[1]).resolve()))
