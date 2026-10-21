# WeOwnFeed (WOF) server image. One image runs every backend process;
# docker-compose.yml picks the command (api, worker, ingest, watcher).
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

RUN useradd --create-home --uid 1000 wof && chown -R wof:wof /app
USER wof

EXPOSE 8000

# Database migrations run on API startup (main.py lifespan).
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
