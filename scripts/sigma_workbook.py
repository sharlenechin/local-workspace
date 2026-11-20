"""Pull and push a Sigma workbook's code representation.

The Sigma MCP connector is READ-ONLY. The REST API is the only write path, via
the Beta endpoint `PUT /v2/workbooks/{id}/contents`.

    mise run sigma -- token                       # do the credentials work?
    mise run sigma -- pull <workbookId> <file>    # save the YAML
    mise run sigma -- push <workbookId> <file>    # publish it back

⚠⚠ PUSH IS A FULL REPLACEMENT. Sigma does not support partial updates: the
entire workbook representation goes in every call, so a truncated or malformed
body replaces the dashboard. This script therefore refuses to push unless you
pass --yes, and it always writes a timestamped backup of the file it is about
to send.

⚠⚠ ALWAYS PUSH WITH A documentVersion. Without one the API is last-write-wins
and will silently discard an edit someone made in the UI since you pulled.
--force skips the check and is there for recovery, not for convenience.

⚠ CREDENTIALS NEVER GO IN THE REPO. Read from the environment:
    SIGMA_CLIENT_ID, SIGMA_CLIENT_SECRET
Put them in `mise.local.toml` or `.env` -- both are gitignored. Creating them
needs the Admin account type or the "Create API keys" permission, and the
credential's OWNER must hold "Create, edit, and publish workbooks" plus
"Can edit" on the workbook itself, or the push returns 403.

⚠ The token is valid for ONE HOUR. This script fetches a fresh one per run.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("SIGMA_API_BASE", "https://api.sigmacomputing.com")


def _request(method: str, path: str, token: str | None = None, body: bytes | None = None,
             content_type: str | None = None, accept: str = "application/json"):
    req = urllib.request.Request(f"{BASE}{path}", method=method, data=body)
    req.add_header("Accept", accept)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def get_token() -> str:
    cid, secret = os.environ.get("SIGMA_CLIENT_ID"), os.environ.get("SIGMA_CLIENT_SECRET")
    if not cid or not secret:
        sys.exit(
            "SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET are not set.\n"
            "Create them in Sigma: Administration -> Developer access -> Create new\n"
            "-> REST API scope. The secret is shown ONCE. Put both in\n"
            "mise.local.toml or .env (both gitignored), never in a tracked file."
        )
    payload = urllib.parse.urlencode(
        {"grant_type": "client_credentials", "client_id": cid, "client_secret": secret}
    ).encode()
    status, text = _request("POST", "/v2/auth/token", body=payload,
                            content_type="application/x-www-form-urlencoded")
    if status != 200:
        sys.exit(f"Token request failed ({status}): {text[:400]}")
    return json.loads(text)["access_token"]


def cmd_token(_args) -> None:
    get_token()
    print("OK - credentials valid, token issued (1 hour).")


def cmd_pull(args) -> None:
    token = get_token()
    status, text = _request("GET", f"/v2/workbooks/{args.workbook_id}/contents",
                            token=token, accept="application/yaml")
    if status == 404:
        sys.exit(
            "No GET endpoint for workbook contents (404).\n"
            "Only the PUT is documented, so the read path may not exist yet.\n"
            "Copy the YAML out of Sigma's code view by hand and save it to the\n"
            "file instead -- push still works."
        )
    if status != 200:
        sys.exit(f"Pull failed ({status}): {text[:400]}")
    pathlib.Path(args.file).write_text(text)
    print(f"Pulled {len(text):,} bytes -> {args.file}")
    print("⚠ Note its documentVersion and pass it to push, or the push is last-write-wins.")


def cmd_push(args) -> None:
    path = pathlib.Path(args.file)
    if not path.is_file():
        sys.exit(f"No such file: {path}")
    content = path.read_text()
    if not content.strip():
        sys.exit("Refusing to push an empty file -- that would blank the workbook.")

    # ⚠ The backup is the whole safety net: a push replaces everything, so keep
    # the exact bytes that were sent, timestamped, next to the source file.
    stamp = dt.datetime.now().strftime("%Y%m%dT%H%M%S")
    backup = path.with_suffix(path.suffix + f".sent-{stamp}")
    backup.write_text(content)

    if not args.yes:
        print(f"DRY RUN. Would PUT {len(content):,} bytes to workbook {args.workbook_id}.")
        print(f"Backup of exactly what would be sent: {backup}")
        print("⚠ This is a FULL REPLACEMENT of the workbook. Re-run with --yes to send.")
        return
    if not args.document_version and not args.force:
        sys.exit(
            "Refusing to push without --document-version.\n"
            "Without it the API is last-write-wins and will discard any edit made\n"
            "in Sigma since you pulled. Use --force only to recover from a bad push."
        )

    payload = {"contents": content}
    if args.document_version:
        payload["documentVersion"] = args.document_version
    status, text = _request("PUT", f"/v2/workbooks/{args.workbook_id}/contents",
                            token=get_token(), body=json.dumps(payload).encode(),
                            content_type="application/json")
    if status in (409, 412):
        sys.exit(f"Rejected ({status}): the workbook changed since that documentVersion.\n"
                 f"Pull again, re-apply your edit, and push. Do NOT --force past this.\n{text[:300]}")
    if status >= 300:
        sys.exit(f"Push failed ({status}): {text[:400]}\nBackup kept at {backup}")
    print(f"Pushed. Backup of what was sent: {backup}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("token", help="check the credentials").set_defaults(fn=cmd_token)
    p = sub.add_parser("pull", help="save the workbook YAML to a file")
    p.add_argument("workbook_id"); p.add_argument("file"); p.set_defaults(fn=cmd_pull)
    p = sub.add_parser("push", help="publish a file back (FULL REPLACEMENT)")
    p.add_argument("workbook_id"); p.add_argument("file")
    p.add_argument("--yes", action="store_true", help="actually send it")
    p.add_argument("--document-version", help="from the pull; prevents clobbering")
    p.add_argument("--force", action="store_true", help="skip the version check (recovery only)")
    p.set_defaults(fn=cmd_push)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
