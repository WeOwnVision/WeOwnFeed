"""
One-off cleanup after accounts got passwords (routers/auth.py): deletes every
user created by the old username-only login (password_hash IS NULL). Their
likes, comments, follows, followed sites and home cards go with them
(ON DELETE CASCADE).

    python purge_passwordless_users.py         # shows how many would be deleted
    python purge_passwordless_users.py --yes   # deletes them
"""
import argparse
import sys

from db import get_db
from routers.auth import AUTH_DDL


def main() -> int:
    parser = argparse.ArgumentParser(description="Delete users that have no password (pre-auth accounts).")
    parser.add_argument("--yes", action="store_true", help="Actually delete; without it only the count is shown")
    args = parser.parse_args()

    with get_db() as cur:
        cur.execute(AUTH_DDL)
        cur.execute("SELECT username FROM users WHERE password_hash IS NULL ORDER BY created_at;")
        names = [r[0] for r in cur.fetchall()]
        print(f"{len(names)} passwordless user(s): {', '.join(names) if names else '-'}")
        if not names or not args.yes:
            if names:
                print("Nothing deleted. Run again with --yes to delete them.")
            return 0
        cur.execute("DELETE FROM users WHERE password_hash IS NULL;")
        print(f"Deleted {cur.rowcount} user(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
