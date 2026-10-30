# kitchen-daylight-docker

Local development and test environment for the Kitchen Daylight restaurant app. One command starts what the applications connect to: PostgreSQL 18 with PostGIS 3.6, Mailpit and an S3-compatible emulator (SeaweedFS). An optional `apps` profile adds the API and Caddy, and a throw-away stack serves the end-to-end tests.

## What this is, and what it is not

- **It is** the dependency stack for the NestJS API, the Angular admin and the Expo mobile app, which live in the separate monorepo `kitchen-daylight`. By default only dependencies run; the API runs on your host with hot reload.
- **It is not** a deployment, a production or demo configuration (that is `infra/` in the monorepo), application code, or a place for real data.

> **Local only.** Every credential in this repository is a local placeholder (`CHANGE_ME_LOCAL`), and every published port is bound to `127.0.0.1`. Never reuse a credential outside a local machine, and never copy these defaults into a real setup.

## Prerequisites

| Tool | Minimum |
|---|---|
| Docker Engine | 20.10.23 |
| Docker Compose plugin (`docker compose`, not `docker-compose`) | 2.24.1 |
| bash | 3.2 |
| curl | 7.75.0 |

The reasons are in [docs/decisions/0003-prerequisites-and-slot.md](docs/decisions/0003-prerequisites-and-slot.md). Apple Silicon (arm64) and amd64 are both supported natively.

You also need several GB of free disk space for Docker (on Docker Desktop: the disk image). With an almost full disk the S3 emulator fails object uploads with HTTP 500 while bucket creation still looks fine.

## Quick start

```bash
scripts/init-env.sh     # once after cloning: writes .env and .env.test for slot 2
scripts/up.sh           # starts PostgreSQL, Mailpit and the S3 emulator, waits until healthy
scripts/print-env.sh    # prints the connection strings and application variables
scripts/status.sh       # one line per service: state, health, port
scripts/down.sh         # stops and removes the containers; keeps the data volumes
```

Optionally run `scripts/verify.sh` while the stack is up for the runtime checks. Every script documents its options with `--help`.

## Ports

Every port is `base + slot x 10`. The default slot is **2**; the test stack uses the same slot with **+5**.

| Service | Slot 2 (dev) | Slot 2 test (+5) | Profile |
|---|---|---|---|
| PostgreSQL | 5452 | 5457 | default / test |
| Mailpit SMTP | 1045 | 1050 | default / test |
| Mailpit web UI | 8045 | 8050 | default / test |
| S3 emulator API | 9020 | 9025 | default / test |
| S3 emulator Admin UI | 9021 | 9026 | default (only if published) |
| API | 3020 | 3025 | `apps` / test |
| Caddy HTTP | 8020 | not used | `apps` |

To use another slot, pass it to the script (every port is base + slot x 10):

```bash
scripts/init-env.sh 3
```

- Never copy `.env.example` by hand: the script computes the ports.
- The script refuses (exit 3) when `.env` or `.env.test` already exists, and says so in its output together with the option that overwrites them (see `scripts/init-env.sh --help`). It also refuses when a port of the slot is already listening: pick another slot or stop the stack that uses the port.

## Connection strings

`scripts/print-env.sh` prints these (slot 2 shown); `--shell` prints `export` lines instead.

```
DATABASE_URL_MIGRATOR=postgres://kd_migrator:<password>@127.0.0.1:5452/kd_dev
DATABASE_URL_APP=postgres://kd_app:<password>@127.0.0.1:5452/kd_dev
MAIL_SMTP_HOST=127.0.0.1
MAIL_SMTP_PORT=1045
MAIL_UI_URL=http://127.0.0.1:8045
STORAGE_S3_ENDPOINT=http://127.0.0.1:9020
STORAGE_S3_FORCE_PATH_STYLE=true
STORAGE_S3_BUCKET_MEDIA=kd-dev-media
STORAGE_S3_BUCKET_PRIVATE=kd-dev-private
APP_ENV=dev
```

The real output also contains the S3 access key and secret. The variable names are a contract with the monorepo: renaming one is a breaking change.

## Profiles and the test stack

| Stack | Command | Notes |
|---|---|---|
| Dependencies only (default) | `scripts/up.sh` | PostgreSQL, Mailpit, S3 emulator |
| With the API and Caddy | `scripts/up.sh --apps` | Pulls the API image named by `API_TAG` in `versions.env`, which the monorepo's CI publishes; it fails until that image exists. Run `scripts/gen-dev-secrets.sh` first for the local JWT and HMAC keys |
| End-to-end test stack | `scripts/test-up.sh` | Own project `kd-docker-test`, clean database on tmpfs, migrations and synthetic seed on every start; writes `.env.test.out` for the consumers |
| Stop the test stack | `scripts/test-down.sh` | Removes its containers and volumes; always safe |

`scripts/seed.sh reference|business|demo` runs the API image's seed command against the dev database. It is a dry run unless you add `--commit`, it needs the stack started with `scripts/up.sh --apps`, and `demo` is refused unless `APP_ENV=dev`.

## Reset

`scripts/down.sh` keeps your data. To delete the dev database and the S3 data and start from scratch:

```bash
scripts/reset.sh     # prints what it removes, then asks you to type: reset kd-docker
```

Anything other than the exact text removes nothing (exit 3). This is the only dev script that deletes data. Use it also to make changed init scripts run again (see the troubleshooting table).

## Environment files

| File | In git | What it is |
|---|---|---|
| `versions.env` | yes | Pinned image references (tag and digest). Edit it only to change a version |
| `.env.example` | yes | Template with the slot 2 values and placeholder passwords |
| `.env`, `.env.test` | no (ignored) | Generated by `scripts/init-env.sh`: dev stack and test stack |

After changing `postgres/Dockerfile` or the pins in `versions.env`, run `scripts/up.sh --build` (it recreates the database container). Do not use `--build` on every start: each build gives the image a new digest and Compose recreates the container.

## Troubleshooting

Script exit codes: `0` success, `1` the operation failed, `2` usage or missing prerequisite (no `.env`, Docker not running), `3` refused for safety (port or slot in use, reset not confirmed).

| Symptom | Cause | Fix |
|---|---|---|
| `init-env.sh` exits 3, or a container cannot bind its port | Another stack already listens on a port of the slot | Stop the stack that uses the port, or run `scripts/init-env.sh <slot>` with a free slot (the script tells you which option overwrites the existing `.env`) |
| A script says "run scripts/init-env.sh <slot>" and exits 2 | `.env` is missing | Run `scripts/init-env.sh` |
| I changed a file in `postgres/init/` and nothing happens | Init scripts run only on an empty data directory, so an existing volume ignores them | `scripts/reset.sh`, then `scripts/up.sh`. Changes that existing databases need belong in the monorepo's migrations |
| The database never gets healthy on the first start, or stays half-initialised | The container was stopped while the init scripts were running | `scripts/reset.sh`, then `scripts/up.sh` and wait for it to finish |
| Slow start, crashes or an `amd64` warning on Apple Silicon | An amd64-only image runs under emulation. The official `postgis/postgis:18-3.6` image is amd64 only | Use the image this repository builds (`postgres/Dockerfile`, native on arm64 and amd64) and keep the pins in `versions.env`; do not swap in another PostGIS image |
| Containers are killed or the machine is slow | Docker Desktop memory is shared by all your stacks. The default stack peaks at about 0.18 GB; the `apps` and test stacks add up to about 1.1 GB by their limits | Run `docker stats`, stop stacks you do not need, raise the memory in Docker Desktop. Keep `apps` opt-in |
| S3 uploads fail with HTTP 500, or the S3 container will not stop | The Docker disk is almost full | Free disk space in Docker; the container may need a hard kill |
| S3 client fails on `127.0.0.1` | Clients default to virtual-hosted addressing | Set `STORAGE_S3_FORCE_PATH_STYLE=true`, as `print-env.sh` prints it |
| Mailpit is empty after a restart | Messages are kept in memory only, on purpose | Do not depend on old messages |
| A container cannot reach a service on your host at `127.0.0.1` | Inside a container `127.0.0.1` is the container itself | Use the service name between containers and `host.docker.internal` for the host |
| `base name should not be blank` from plain `docker compose` | Compose reads only `.env`, not `versions.env` | Use the scripts, or pass both files: `docker compose --env-file .env --env-file versions.env ...` |
| `.sh` files fail with a cryptic error on Windows | A checkout turned them into CRLF | `.gitattributes` forces LF; check out again with it in place |

## Documentation

The design, decisions, scripts contract and risks are in [docs/README.md](docs/README.md).

## License

All rights reserved. See [LICENSE](LICENSE).
