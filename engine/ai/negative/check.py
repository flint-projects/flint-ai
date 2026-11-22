#!/usr/bin/env python3
"""Compile the AI schema and registry misuse fixtures and require named diagnostics."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
# Each unsupported DTO must name the offending field; the registry must name the duplicate rule.
CASES = (
    ("pointer_schema.d", "unsupported JSON Schema field PointerArgument.cursor"),
    ("delegate_schema.d", "unsupported JSON Schema field CallableArgument.routine"),
    ("cyclic_schema.d", "unsupported JSON Schema field NodeArgument.next"),
    ("slice_cycle_schema.d", "unsupported JSON Schema field TreeArgument.children"),
    ("duplicate_tools.d", "duplicate names in the tool registry"),
)
PACKAGES = ("ai", "arena", "conc", "http", "reactor", "serde", "validate")


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("compilers", nargs="+")
    args = cli.parse_args()
    imports = ["-I" + str(ROOT / "packages" / name / "source") for name in PACKAGES]
    for compiler in args.compilers:
        for filename, diagnostic in CASES:
            command = [compiler, "-preview=dip1000", "-c", "-o-", *imports, str(HERE / filename)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=120)
            output = result.stdout + result.stderr
            assert 0 < result.returncode < 128 and diagnostic in output, (compiler, filename, output)
            assert "internal compiler error" not in output.lower(), (compiler, filename, output)
            print(f"{compiler}: {filename} rejected ({diagnostic})")


if __name__ == "__main__":
    main()
