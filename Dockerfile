FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates \
        libcurl4-openssl-dev libmicrohttpd-dev libsqlite3-dev \
        build-essential cmake git ninja-build pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install Koka — pinned to a specific release for reproducible builds.
ARG KOKA_VERSION=v3.2.3
RUN curl -sSL https://github.com/koka-lang/koka/releases/download/${KOKA_VERSION}/install.sh | sh
ENV PATH="/root/.local/bin:/usr/local/bin:$PATH"

# Install hica — pinned likewise.
ARG HICA_VERSION=v0.42.5
RUN curl -fsSL https://github.com/cladam/hica/releases/download/${HICA_VERSION}/install.sh | sh

WORKDIR /build
COPY . .

# Strip macOS-only homebrew paths from hica.hml — not needed on Linux
# where headers/libs live in standard system paths.
RUN sed -i \
        -e 's| --ccincdir=/opt/homebrew/include||g' \
        -e 's| --cclinkopts=-L/opt/homebrew/lib||g' \
        hica.hml

RUN hica build -o hica-registry

FROM debian:bookworm-slim

# libmicrohttpd12 is the Debian Bookworm package name; verify when bumping the base image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcurl4 libmicrohttpd12 libsqlite3-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/src/hica-registry ./hica-registry

# Create a dedicated non-root user for the server process.
RUN adduser --system --no-create-home --group hica

# Tarball store and database are runtime data — mount these as volumes.
#
#   docker run -d \
#     -p 8080:8080 \
#     -v /host/data/registry.db:/app/registry.db \
#     -v /host/data/tarballs:/app/tarballs \
#     -e HICA_REGISTRY_ADMIN_TOKEN_HASH=sha256:<hash> \
#     hica-registry
#
# Generate the token hash:
#   echo -n "your-secret-token" | sha256sum | awk '{print "sha256:" $1}'
RUN mkdir -p tarballs && chown hica:hica tarballs

# Declare the volume so orchestrators know these paths hold persistent data.
VOLUME ["/app/tarballs"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

EXPOSE 8080

ENV HICA_TARBALL_DIR=/app/tarballs

USER hica

CMD ["./hica-registry"]
