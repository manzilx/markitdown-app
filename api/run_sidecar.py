"""Entry point for the bundled Windows sidecar executable."""

from __future__ import annotations

import sys


def parse_port(argv: list[str], default: int = 8001) -> int:
    """Parse ``--port N`` or ``--port=N`` from argv (excluding the program name).

    Never raises: the helper must come up on the default port rather than crash
    on unexpected arguments.
    """
    for i, arg in enumerate(argv):
        value: str | None = None
        if arg == "--port" and i + 1 < len(argv):
            value = argv[i + 1]
        elif arg.startswith("--port="):
            value = arg.split("=", 1)[1]
        if value is not None:
            try:
                return int(value)
            except ValueError:
                return default
    return default


def main() -> None:
    import uvicorn

    uvicorn.run(
        "markitdown_api.main:app",
        host="127.0.0.1",
        port=parse_port(sys.argv[1:]),
        log_level="info",
        access_log=False,
    )


if __name__ == "__main__":
    main()
