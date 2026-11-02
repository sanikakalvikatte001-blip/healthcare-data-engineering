# Optional: a local PostgreSQL 16 with the extensions this project needs.
#   docker build -t mpi-pg . && docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=postgres mpi-pg
# fuzzystrmatch and pg_trgm ship with the image (contrib); pgTAP is added here.
FROM postgres:16
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-pgtap \
 && rm -rf /var/lib/apt/lists/*
