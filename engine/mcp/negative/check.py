#!/usr/bin/env python3
"""Compile the MCP borrow and registry misuse fixtures and require their stable diagnostics."""
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
CASES = (
    ("leak_input.d", r"scope variable `query`.*global variable `leaked`"),
    ("unsafe_provider.d", r"MCP tool must be @safe nothrow @nogc and return Result!ToolResult"),
)
PACKAGES = ("arena", "conc", "http", "reactor", "serde", "validate", "web", "mcp")


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("compilers", nargs="+")
    args = cli.parse_args()
    imports = ["-I" + str(ROOT / "packages" / name / "source") for name in PACKAGES]
    for compiler in args.compilers:
        for filename, pattern in CASES:
            command = [compiler, "-preview=dip1000", "-c", "-o-", *imports, str(HERE / filename)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=120)
            output = result.stdout + result.stderr
            assert 0 < result.returncode < 128 and re.search(pattern, output), (compiler, filename, output)
            assert "internal compiler error" not in output.lower(), (compiler, filename, output)
            print(f"{compiler}: {filename} rejected")


if __name__ == "__main__":
    main()
