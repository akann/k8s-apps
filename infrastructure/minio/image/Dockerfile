# MinIO server, built from source and pushed to Harbor.
#
# Why this exists: as of ~2026-09-25 MinIO's published images are no longer
# anonymously pullable — quay.io/minio/minio and Docker Hub minio/minio both
# answer 401 to a manifest request, and the release binaries on dl.min.io
# answer 410 Gone. The chart's default image therefore can't be pulled on any
# node that doesn't already have it cached, which took MinIO down when its pod
# was rescheduled onto k8s-worker-1. See UPDATES.md (2026-09-28).
#
# Same release the chart (5.4.0) defaulted to, so this is a like-for-like
# replacement, not an upgrade. The source is pinned to the tag's commit, not
# just the tag name, so a re-pointed tag can't change what gets built.
#
# Build + push (from the repo root, on any arch — Go cross-compiles, no
# emulation needed):
#
#   docker buildx build --platform linux/amd64 \
#     -t harbor.yanatech.co.uk/library/minio:RELEASE.2024-12-18T13-15-44Z \
#     --push infrastructure/minio/image

ARG MINIO_RELEASE=RELEASE.2024-12-18T13-15-44Z
ARG MINIO_COMMIT=16f8cf1c52f0a77eeb8f7565aaf7f7df12454583

# go.mod at this release says `go 1.23`.
FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS build
ARG MINIO_RELEASE
ARG MINIO_COMMIT
ARG TARGETOS
ARG TARGETARCH

RUN apk add --no-cache git ca-certificates

WORKDIR /src
RUN git init -q . \
 && git remote add origin https://github.com/minio/minio.git \
 && git fetch -q --depth 1 origin "$MINIO_COMMIT" \
 && git checkout -q FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "$MINIO_COMMIT"

# Mirrors the upstream Makefile's `build` target. ⚠️ gen-ldflags wants
# MINIO_RELEASE to be the PREFIX only ("RELEASE") and appends the commit time
# itself, which is exactly this tag's timestamp. Passing the full tag name
# doubles it ("RELEASE.2024-…Z.2024-…Z"), and MinIO parses that string
# internally. Without it at all, the binary reports a DEVELOPMENT build.
RUN MINIO_RELEASE=RELEASE go run buildscripts/gen-ldflags.go > /tmp/ldflags \
 && CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -tags kqueue -trimpath --ldflags "$(cat /tmp/ldflags)" -o /out/minio

# Upstream uses ubi-micro. Alpine is used here because the chart's container
# command is `/bin/sh -ce "/usr/bin/docker-entrypoint.sh minio server ..."`,
# so the image needs a shell, and the entrypoint script is POSIX sh.
FROM alpine:3.20
ARG MINIO_RELEASE

LABEL org.opencontainers.image.title="minio" \
      org.opencontainers.image.version="${MINIO_RELEASE}" \
      org.opencontainers.image.source="https://github.com/minio/minio" \
      org.opencontainers.image.licenses="AGPL-3.0"

# Same env as upstream's Dockerfile.release.
ENV MINIO_ACCESS_KEY_FILE=access_key \
    MINIO_SECRET_KEY_FILE=secret_key \
    MINIO_ROOT_USER_FILE=access_key \
    MINIO_ROOT_PASSWORD_FILE=secret_key \
    MINIO_KMS_SECRET_KEY_FILE=kms_master_key \
    MINIO_UPDATE_MINISIGN_PUBKEY="RWTx5Zr1tiHQLwG9keckT0c45M3AGeHD6IvimQHpyRywVWGbP1aVSGav" \
    MINIO_CONFIG_ENV_FILE=config.env \
    MC_CONFIG_DIR=/tmp/.mc

RUN apk add --no-cache ca-certificates

COPY --from=build /out/minio /usr/bin/minio
COPY --from=build /src/dockerscripts/docker-entrypoint.sh /usr/bin/docker-entrypoint.sh
COPY --from=build /src/LICENSE /src/CREDITS /licenses/
RUN chmod +x /usr/bin/minio /usr/bin/docker-entrypoint.sh

EXPOSE 9000
VOLUME ["/data"]

ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
CMD ["minio"]
