# syntax=docker/dockerfile:1
FROM debian:bookworm-slim AS build

ARG TARGETARCH
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Official Zig 0.16.0 archives; verify SHA-256 before extracting.
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) zig_arch=x86_64; zig_sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;; \
      arm64) zig_arch=aarch64; zig_sha=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;; \
      *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fSL "https://ziglang.org/download/0.16.0/zig-${zig_arch}-linux-0.16.0.tar.xz" -o /tmp/zig.tar.xz; \
    echo "$zig_sha  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"
WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ ./src/
COPY migrations/ ./migrations/
RUN zig build test && zig build -Doptimize=ReleaseSafe

FROM debian:bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/zig-out/bin/musica-backend /usr/local/bin/musica-backend
USER 10001:10001
ENV HTTP_HOST=0.0.0.0 HTTP_PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=5 \
    CMD curl --fail --silent --max-time 3 "http://127.0.0.1:${HTTP_PORT}/api/health" || exit 1
ENTRYPOINT ["/usr/local/bin/musica-backend"]
