"""Keep script imports available for package-form unittest commands."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
