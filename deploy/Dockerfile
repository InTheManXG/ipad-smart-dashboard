FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DISPLAY_MODE=pairing \
    DISPLAY_BIND=0.0.0.0 \
    RELAY_DATA_DIR=/relay-data

RUN groupadd --gid 10001 dashboard \
    && useradd --uid 10001 --gid dashboard --no-create-home --shell /usr/sbin/nologin dashboard \
    && mkdir -p /dashboard /relay-data \
    && chown dashboard:dashboard /relay-data
WORKDIR /dashboard
COPY server.py pairing.py relay.py music.py ./
COPY web ./web
USER 10001:10001
VOLUME ["/relay-data"]
EXPOSE 18086
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python3 -c "import json,urllib.request; assert json.load(urllib.request.urlopen('http://127.0.0.1:18086/api/mode',timeout=3))['mode']=='pairing'"
CMD ["python3", "server.py"]
