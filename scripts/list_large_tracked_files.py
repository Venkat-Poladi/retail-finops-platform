from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MINIMUM_BYTES = 1_000_000


def main() -> None:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        capture_output=True,
        check=True,
    )

    paths = [
        ROOT / raw.decode("utf-8")
        for raw in result.stdout.split(b"\0")
        if raw
    ]

    large_files = sorted(
        (
            (path.stat().st_size, path.relative_to(ROOT))
            for path in paths
            if path.is_file() and path.stat().st_size >= MINIMUM_BYTES
        ),
        reverse=True,
    )

    if not large_files:
        print("No tracked files are 1 MB or larger.")
        return

    print("Tracked files of 1 MB or larger:")
    for size, path in large_files:
        print(f"{size / 1_000_000:8.2f} MB  {path}")


if __name__ == "__main__":
    main()
