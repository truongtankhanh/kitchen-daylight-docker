# Changelog

All notable changes to this repository are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

Entries for the first release, `0.1.0` (see `docs/release-process.md`).

### Added

- Repository skeleton: `.gitignore`, `.gitattributes`, `.editorconfig`, `README.md`, `CHANGELOG.md`, `VERSION`, all-rights-reserved `LICENSE`.
- Dependency stack (`compose.yaml`): PostgreSQL 18 with PostGIS 3.6 (thin image built from `postgres/Dockerfile`), Mailpit, and an S3-compatible emulator with a bucket-creating `s3-init` job; named volumes `pgdata` and `s3data`.
- PostgreSQL init scripts (`postgres/init/`): roles `kd_migrator` and `kd_app`, databases, extensions (`postgis`, `pg_trgm`, `unaccent`, `citext`) and default privileges.
- Port scheme: every published port is bound to `127.0.0.1` and computed as `base + slot x 10` by `scripts/init-env.sh`; the test stack adds 5. `.env.example` holds local placeholders only (`CHANGE_ME_LOCAL`).
- `versions.env`: one place for image pins, every reference as `tag@digest`.
- `apps` profile (`compose.apps.yaml`): `migrate`, `api` and `caddy`, started with `scripts/up.sh --apps`.
- End-to-end test stack (`compose.test.yaml`, project `kd-docker-test`, PostgreSQL data on tmpfs): `scripts/test-up.sh` writes `.env.test.out` for consumers, `scripts/test-down.sh`, optional fast reset with `scripts/test-reset-db.sh`.
- Scripts (contract in `docs/4-scripts-contract.md`): `init-env.sh`, `gen-dev-secrets.sh`, `up.sh`, `down.sh`, `status.sh`, `wait-healthy.sh`, `print-env.sh`, `reset.sh`, `seed.sh`, `verify.sh`, `test-up.sh`, `test-down.sh`, `test-reset-db.sh`, `lint-compose.sh`, `check-parity.sh`.
- Safety checks: `scripts/lint-compose.sh` rejects non-loopback binds, `container_name`, `restart: always`, `latest` or untagged images and tracked `.env` files; `scripts/verify.sh` checks the running dev stack.
- `scripts/check-parity.sh <monorepo>/infra` compares the PostgreSQL image, PostGIS version, Caddy tag and `API_TAG` with the monorepo's pins.
- CI (GitHub Actions): `lint.yml`, `smoke.yml`, `secrets.yml`, and Dependabot for GitHub Actions and the base images listed in `deps/Dockerfile.pins`.
- Documentation: `docs/` (overview and decisions, services and ports, Compose files and profiles, scripts contract, test stack and CI, gotchas and risks, API and consumer contracts, decision records, release process).
