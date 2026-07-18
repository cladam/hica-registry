FROM debian:bookworm-slim

# Download the latest hica-registry release binary from GitHub.
# To pin to a specific version, replace "latest/download" with
# "download/v0.3.0" in the URL below.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates \
        libcurl4 libmicrohttpd12 libsqlite3-0 \
    && ARCH=$(uname -m | sed 's/aarch64/arm64/') \
    && curl -fsSL "https://github.com/cladam/hica-registry/releases/latest/download/hica-registry-linux-${ARCH}" \
       -o /usr/local/bin/hica-registry \
    && chmod +x /usr/local/bin/hica-registry \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

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

CMD ["/usr/local/bin/hica-registry"]
