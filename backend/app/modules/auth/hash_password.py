"""CLI: ``uv run python -m app.modules.auth.hash_password [--stdin]`` (auth spec §7.5).

Prints an argon2id PHC hash on stdout. Needs no environment variables. Never prints or logs the password.
Exit codes: 1 = passwords did not match, 2 = password shorter than 8 characters.
"""

from __future__ import annotations

import argparse
import getpass
import sys

from app.modules.auth.security import PasswordHasher

MIN_LENGTH = 8


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Hash a password with argon2id for OWNER_PASSWORD_HASH.")
    parser.add_argument("--stdin", action="store_true", help="read one line from stdin instead of prompting")
    args = parser.parse_args(argv)

    if args.stdin:
        password = sys.stdin.readline().rstrip("\r\n")
    else:
        password = getpass.getpass("Password: ")
        if getpass.getpass("Repeat: ") != password:
            print("Passwords do not match.", file=sys.stderr)
            return 1
    if len(password) < MIN_LENGTH:
        print(f"Password must be at least {MIN_LENGTH} characters.", file=sys.stderr)
        return 2

    print(PasswordHasher().hash(password))
    print(
        "Note: the hash contains '$' - wrap it in single quotes in shells and .env files; "
        "paste it as-is in the Render dashboard.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
