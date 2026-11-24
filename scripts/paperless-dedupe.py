#!/usr/bin/env python3
"""Soft-delete exact duplicate documents in Paperless-ngx.

Runs inside the Paperless container, so it uses the Django ORM and Paperless'
own bulk-delete task (which also updates the search index). It groups by the
same original/archive checksums as the Duplicates view, keeps one document per
group, and leaves the rest in the trash.

Default is a dry run. Pass --apply to soft-delete.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections import defaultdict

sys.path.insert(0, "/usr/src/paperless/src")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "paperless.settings")


def load_secret_files() -> None:
    """Resolve PAPERLESS_*_FILE like the image's s6 init does.

    A raw `docker exec` does not pass through s6's init-env-file, so
    PAPERLESS_SECRET_KEY and PAPERLESS_DBPASS are absent unless we read them.
    """
    skip = {"PAPERLESS_OCR_SKIP_ARCHIVE_FILE", "PAPERLESS_MODEL_FILE"}
    for key, path in list(os.environ.items()):
        if key in skip or not key.startswith("PAPERLESS_") or not key.endswith("_FILE"):
            continue
        target = key[: -len("_FILE")]
        if target in os.environ:
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                os.environ[target] = handle.read()
        except OSError as exc:
            print(f"WARNING: cannot read {key}={path}: {exc}", file=sys.stderr)


load_secret_files()

import django  # noqa: E402

django.setup()

from documents import bulk_edit  # noqa: E402
from documents.models import Document  # noqa: E402


def metadata_score(doc: Document) -> tuple[int, int]:
    """Prefer the copy with more metadata, then the oldest id."""
    score = (
        bool(doc.correspondent_id)
        + bool(doc.document_type_id)
        + bool(doc.storage_path_id)
        + doc.tags.count()
    )
    return (score, -doc.id)


def duplicate_groups() -> list[list[Document]]:
    docs = list(
        Document.objects.filter(root_document__isnull=True)
        .only(
            "id",
            "title",
            "checksum",
            "archive_checksum",
            "correspondent_id",
            "document_type_id",
            "storage_path_id",
        )
        .prefetch_related("tags")
    )

    parent: dict[int, int] = {}

    def find(doc_id: int) -> int:
        parent.setdefault(doc_id, doc_id)
        while parent[doc_id] != doc_id:
            parent[doc_id] = parent[parent[doc_id]]
            doc_id = parent[doc_id]
        return doc_id

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    first_by_checksum: dict[str, int] = {}
    for doc in docs:
        for checksum in {doc.checksum, doc.archive_checksum}:
            if not checksum:
                continue
            if checksum in first_by_checksum:
                union(doc.id, first_by_checksum[checksum])
            else:
                first_by_checksum[checksum] = doc.id

    groups: dict[int, list[Document]] = defaultdict(list)
    for doc in docs:
        groups[find(doc.id)].append(doc)

    return [group for group in groups.values() if len(group) > 1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="actually soft-delete the duplicates (default: dry run)",
    )
    parser.add_argument(
        "--show",
        type=int,
        default=20,
        help="number of groups to print in the report (default: 20)",
    )
    args = parser.parse_args()

    groups = duplicate_groups()
    if not groups:
        print("No exact duplicate groups found.")
        return 0

    total_duplicates = sum(len(group) - 1 for group in groups)
    print(f"Found {len(groups)} duplicate group(s), {total_duplicates} extra file(s).")

    to_delete: list[int] = []
    for group in sorted(groups, key=lambda g: (-len(g), g[0].id))[: args.show]:
        keeper = max(group, key=metadata_score)
        others = [d for d in group if d.id != keeper.id]
        print(
            f"  group of {len(group)}: keep {keeper.id} "
            f"({keeper.title!r}); delete {', '.join(str(d.id) for d in others)}",
        )

    for group in groups:
        keeper = max(group, key=metadata_score)
        to_delete.extend(d.id for d in group if d.id != keeper.id)

    if not args.apply:
        print(
            f"Dry run: would soft-delete {len(to_delete)} document(s). "
            "Re-run with --apply to do it.",
        )
        return 0

    for start in range(0, len(to_delete), 500):
        batch = to_delete[start : start + 500]
        bulk_edit.delete(batch)
        print(f"Soft-deleted {len(batch)} document(s) (batch {start // 500 + 1}).")

    print(
        "Done. Duplicates are in the trash; empty the trash to reclaim disk. "
        "The Duplicates view includes trashed documents until then.",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
