# Faster build for production deploy — installs ZMQ/sodium from apt
# instead of compiling from source like the upstream Dockerfile does.
FROM golang:1.27-bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    libzmq3-dev libsodium-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /go/src/fleet-telemetry
COPY . .

ENV CGO_ENABLED=1
RUN make

# ── runtime ──────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libzmq5 libsodium23 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /go/bin/fleet-telemetry /fleet-telemetry

EXPOSE 4443 8080 9090
ENTRYPOINT ["/fleet-telemetry"]
CMD ["-config", "/etc/fleet-telemetry/config.json"]
