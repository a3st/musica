# syntax=docker/dockerfile:1
# Build official source releases because their prebuilt registries are unavailable.
FROM golang:1.24-alpine AS toolchain
RUN apk add --no-cache ca-certificates git
ENV CGO_ENABLED=0 GOTOOLCHAIN=local

FROM toolchain AS minio-build
RUN git clone --depth 1 --branch RELEASE.2025-09-07T16-13-09Z https://github.com/minio/minio.git /src \
    && test "$(git -C /src rev-parse HEAD)" = "07c3a429bfed433e49018cb0f78a52145d4bedeb"
WORKDIR /src
RUN go build -p 2 -trimpath -ldflags="-s -w" -o /out/minio .

FROM toolchain AS mc-build
RUN git clone --depth 1 --branch RELEASE.2025-08-13T08-35-41Z https://github.com/minio/mc.git /src \
    && test "$(git -C /src rev-parse HEAD)" = "7394ce0dd2a80935aded936b09fa12cbb3cb8096"
WORKDIR /src
RUN go build -p 2 -trimpath -ldflags="-s -w" -o /out/mc .

FROM alpine:3.22 AS runtime
RUN apk add --no-cache ca-certificates tzdata \
    && mkdir -p /data /home/minio \
    && chown -R 10002:10002 /data /home/minio
COPY --from=minio-build /out/minio /usr/local/bin/minio
COPY --from=mc-build /out/mc /usr/local/bin/mc
ENV HOME=/home/minio
USER 10002:10002
EXPOSE 9000 9001
ENTRYPOINT ["/usr/local/bin/minio"]
CMD ["server", "/data", "--console-address", ":9001"]
