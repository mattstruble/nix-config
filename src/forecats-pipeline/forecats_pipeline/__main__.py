"""`python3 -m forecats_pipeline` — the nightly entry point."""

import sys

from forecats_pipeline.pipeline import main

if __name__ == "__main__":
    sys.exit(main())
