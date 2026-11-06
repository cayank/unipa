"""Write recovery and injection artifacts without overwriting existing files"""

import json
from pathlib import Path

def write_new(path: Path, data: bytes, mode: int = 0o600) -> None:
    with path.open("xb") as handle:
        handle.write(data)
    path.chmod(mode)

def write_json(path: Path, value: dict) -> None:
    write_new(path, (json.dumps(value, indent=2) + "\n").encode())
