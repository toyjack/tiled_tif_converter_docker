# Repository Guidelines

## Agent Communication

Communicate with the user exclusively in Chinese. Keep repository documentation in English.

## Project Structure & Module Organization

- `process_images.sh` contains TIFF discovery, resume checks, cache management, and GNU Parallel workers. Conversion uses libvips to produce Deflate-compressed, 256×256 tiled pyramid TIFFs.
- `dockerfile` defines the Alpine runtime; `docker-compose.yaml` configures the `image-processor` service, mounts, and resource limits.
- `.env.example` documents deployment settings. `CLAUDE.md` and `prd.md` provide background; verify their claims against the current implementation.
- `input/`, `output/`, and `logs/` are runtime directories excluded from Git. There are no separate source, test, or asset directories.

## Build, Test, and Development Commands

Use Docker with Compose and Bash (for example, WSL on Windows).

- `cp .env.example .env`: initialize local configuration; adjust directory paths and resource limits as needed.
- `docker compose config`: validate configuration and environment interpolation.
- `docker build -f dockerfile -t tiled-tif-converter .`: build explicitly from the lowercase Dockerfile.
- `docker compose up --build image-processor`: build and run a conversion batch.
- `docker compose logs -f image-processor`: follow service output.
- `bash -n process_images.sh`: check Bash syntax without executing conversions.

Compose explicitly selects the lowercase `dockerfile`. The container runs as `vipsuser` (UID/GID 1000); bind-mounted output and log directories must be writable by that user on Linux hosts.

## Coding Style & Naming Conventions

Use two-space indentation in Bash and YAML, LF line endings, `snake_case` functions and local variables, and `UPPER_SNAKE_CASE` configuration variables. Quote path expansions and preserve null-delimited file handling. Export worker dependencies when adding functions used by GNU Parallel. No formatter or linter is configured.

## Testing Guidelines

No automated framework or coverage threshold exists. For processing changes, run syntax and Compose validation, then exercise small disposable TIFF fixtures in both `USE_LOCAL_CACHE=true` and `false` modes. Cover nested directories, filenames containing spaces, existing outputs, empty input, and corrupt files. Inspect output dimensions, compression, tiling, pyramid levels, and logs; rerun to verify completed files are skipped.

## Commit & Pull Request Guidelines

Follow recent history with concise imperative subjects such as `Refactor disk space check` or `Increase tmpfs size`; no Conventional Commit prefix is established. PRs should describe behavior changes, configuration implications, and validation performed. Link related issues when available. Keep `.env`, image batches, generated outputs, and logs out of commits.
