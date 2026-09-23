FROM python:3.12-slim

WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

COPY pyproject.toml .
# Install runtime deps (resolve from pyproject).
RUN pip install --no-cache-dir \
    "fastapi>=0.115" "uvicorn[standard]>=0.30" "sqlalchemy[asyncio]>=2.0" \
    "asyncpg>=0.29" "aiosqlite>=0.20" "aiomqtt>=2.3" "redis>=5.0" \
    "pydantic>=2.7" "pydantic-settings>=2.3" "pyjwt>=2.8" "python-multipart>=0.0.9"

COPY app ./app

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
