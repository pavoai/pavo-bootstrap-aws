# Stdlib-only service -> no pip install, tiny + air-gap friendly. Non-root.
# Pin the platform to the cluster arch (EKS nodes are amd64). Without this, a
# build on an arm64 host (e.g. Apple Silicon) produces an arm64 image that
# crash-loops on the amd64 nodes with "exec format error". CI must build amd64
# (or multi-arch) — `docker buildx build --platform linux/amd64`.
FROM --platform=linux/amd64 python:3.12-slim

WORKDIR /app
COPY app.py /app/app.py

# Drop privileges.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin sanitizer
USER 10001

EXPOSE 8080
ENTRYPOINT ["python", "/app/app.py"]
