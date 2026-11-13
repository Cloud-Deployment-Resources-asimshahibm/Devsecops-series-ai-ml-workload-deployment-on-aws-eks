import sys
from pathlib import Path

ML = Path(__file__).resolve().parents[1]
for p in (ML / "common", ML / "training", ML / "inference"):
    sys.path.insert(0, str(p))
