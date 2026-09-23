# Canary backend: FastAPI + MQTT consumer. python:3.12-slim is multi-arch, so
# this builds natively on a Raspberry Pi (arm64) as well as on a laptop.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Runtime dependencies come straight from pyproject.toml (single source of
# truth). Installing them before copying the source keeps this slow layer
# cached when only the code changes.
COPY pyproject.toml ./
RUN python -c "import tomllib; print('\n'.join(tomllib.load(open('pyproject.toml', 'rb'))['project']['dependencies']))" \
        > /tmp/requirements.txt \
    && pip install -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

COPY app ./app

# Run unprivileged. The SQLite database lives on the /data volume
# (CANARY_DATABASE_URL=sqlite+aiosqlite:////data/canary.db in docker-compose.yml).
RUN groupadd --gid 10001 canary \
    && useradd --uid 10001 --gid canary --no-create-home --home-dir /data --shell /usr/sbin/nologin canary \
    && mkdir -p /data \
    && chown canary:canary /data
USER canary

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
