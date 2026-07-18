.PHONY: docker-build docker-push docker-prep docker-clean

# Build the Docker image.  Works without any prior preparation — the Dockerfile
# fetches all packages itself via 'hica fetch'.
#
# For faster rebuilds you can optionally run 'make docker-prep' first to
# warm Docker's layer cache with pre-fetched stdlib files.
#
# Usage:
#   make docker-build                  # builds as hica-registry:latest
#   make docker-build TAG=v0.3.0       # custom tag
TAG ?= latest
IMAGE ?= hica-registry

docker-build:
	docker build -t $(IMAGE):$(TAG) .

# Push to a registry. Set IMAGE to the full registry path, e.g.:
#   make docker-push IMAGE=ghcr.io/cladam/hica-registry TAG=v0.3.0
docker-push:
	docker push $(IMAGE):$(TAG)

# Optional: pre-seed the .hica directory from the host so that the
# 'hica fetch' layer inside Docker hits fewer network requests on rebuild.
# Not required — only useful for speeding up repeated local builds.
docker-prep:
	hica fetch
	cp -r ~/.hica/. .hica/

# Remove the pre-seeded cache, leaving only the .gitkeep placeholder.
docker-clean:
	rm -rf .hica/cache .hica/stdlib .hica/*.kk .hica/*.kki 2>/dev/null || true
