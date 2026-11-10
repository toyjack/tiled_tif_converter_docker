#!/usr/bin/env python3
"""Summarize existing TIFF outputs by their containing directory."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


def scan_directories(root):
  """Count direct TIFF children; fail rather than report an incomplete scan."""
  records = []

  def raise_scan_error(error):
    raise error

  for directory, _, filenames in os.walk(root, onerror=raise_scan_error):
    image_count = 0
    latest_mtime = None
    for filename in filenames:
      path = Path(directory) / filename
      if path.suffix.lower() not in {".tif", ".tiff"} or path.is_symlink():
        continue
      file_stat = path.stat()
      if not stat.S_ISREG(file_stat.st_mode):
        continue
      image_count += 1
      latest_mtime = max(latest_mtime, file_stat.st_mtime) if latest_mtime is not None else file_stat.st_mtime
    if image_count:
      records.append({
        "directory_name": Path(directory).relative_to(root).as_posix(),
        "image_count": image_count,
        "completion_date": datetime.fromtimestamp(latest_mtime, timezone.utc).date().isoformat(),
      })
  return sorted(records, key=lambda record: record["directory_name"])


def write_report(records, destination):
  """Replace the report only after the entire JSON has been written."""
  temporary_path = None
  try:
    with tempfile.NamedTemporaryFile(
      mode="w", encoding="utf-8", newline="\n", dir=destination.parent,
      prefix=".completed-images-", suffix=".tmp", delete=False,
    ) as temporary:
      temporary_path = Path(temporary.name)
      json.dump(records, temporary, ensure_ascii=False, indent=2)
      temporary.write("\n")
    os.replace(temporary_path, destination)
  finally:
    if temporary_path is not None and temporary_path.exists():
      temporary_path.unlink()


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("directory", type=Path, help="Converted TIFF directory to scan recursively")
  parser.add_argument("-o", "--output", type=Path, default=Path("completed_images.json"),
                      help="JSON destination (default: completed_images.json)")
  args = parser.parse_args()
  try:
    root = args.directory.resolve(strict=True)
    if not root.is_dir():
      raise NotADirectoryError(f"Not a directory: {root}")
    destination = args.output.absolute()
    if destination.suffix.lower() != ".json":
      parser.error("The output filename must end in .json")
    records = scan_directories(root)
    write_report(records, destination)
  except (OSError, ValueError) as error:
    print(f"Error: {error}", file=sys.stderr)
    return 1
  print(f"Wrote {len(records)} directories to {destination}")
  return 0


if __name__ == "__main__":
  sys.exit(main())
