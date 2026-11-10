# Completed image inventory

Run with Python 3 (standard library only):

```bash
python scan_completed_images.py /path/to/output -o completed_images.json
```

Or use the project's Docker image and configured output mount:

```bash
docker compose run --rm --build --entrypoint python3 image-processor /app/scan_completed_images.py /app/output -o /app/output/completed_images.json
```

The destination parent directory must already exist. An existing JSON report is
replaced atomically after a successful scan. Scan errors produce a nonzero exit
code and preserve the previous report.

Example output:

```json
[
  {
    "directory_name": "collection/slides",
    "image_count": 120,
    "completion_date": "2026-11-10"
  }
]
```

- Each entry counts TIFF files directly inside one directory, without including
  its descendants in the count. Directories without TIFF files are omitted.
- Directory names are paths relative to the scan root, using `/` separators.
  `.` identifies images directly inside the root. Entries are sorted by path.
- `.tif` and `.tiff` extensions are matched case-insensitively. Temporary files
  such as `image.tif.tmp.123`, other extensions, and symbolic links are ignored.
- `completion_date` is the latest TIFF modification date in UTC (`YYYY-MM-DD`).
  It estimates completion because the converter does not store historical
  completion timestamps. Copying or modifying files can change this date.
- Run after conversion finishes. The script inventories existing outputs; it
  does not validate TIFF contents or compare against the input batch to prove
  that a directory is fully converted. Pyramid levels count as one image file.
- An empty scan produces `[]`. Unicode, spaces, and quotes in names are supported.
