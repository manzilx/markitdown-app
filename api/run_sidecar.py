"""Entry point for the bundled Windows sidecar executable."""

from __future__ import annotations

import sys


def main() -> None:
    import uvicorn

    port = 8001
    for i, arg in enumerate(sys.argv[1:], start=1):
        if arg == "--port" and i < len(sys.argv):
            port = int(sys.argv[i])
            break

    uvicorn.run(
        "markitdown_api.main:app",
        host="127.0.0.1",
        port=port,
        log_level="info",
        access_log=False,
    )


if __name__ == "__main__":
    main()
