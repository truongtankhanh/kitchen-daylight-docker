# check=skip=InvalidDefaultArgInFrom
# PostgreSQL 18 with PostGIS 3.6 (docs/decisions/0001-postgis-image.md).
# The official postgres image plus the PGDG package, native on amd64 and arm64.
# Both values come from versions.env through compose.yaml; there is deliberately no default here,
# so the pins live in one place only.
ARG POSTGRES_BASE
FROM ${POSTGRES_BASE}

ARG POSTGIS_PACKAGE_VERSION

# PG_MAJOR is set by the base image. The PGDG apt source is already configured in it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      "postgresql-${PG_MAJOR}-postgis-3=${POSTGIS_PACKAGE_VERSION}" \
      "postgresql-${PG_MAJOR}-postgis-3-scripts=${POSTGIS_PACKAGE_VERSION}" \
 && rm -rf /var/lib/apt/lists/*
