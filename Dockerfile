# syntax=docker/dockerfile:1

# Stage 1: Compile Zig 0.13 i128 + SQLite WAL financial kernel
FROM debian:trixie-slim AS zig-builder
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl xz-utils libsqlite3-dev gcc libc6-dev ca-certificates \
  && curl -fsSL https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz -o /tmp/zig.tar.xz \
  && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
  && ln -s /opt/zig/zig /usr/local/bin/zig
WORKDIR /src
COPY kernel/src/main.zig kernel/src/main.zig
RUN mkdir -p out && zig build-exe kernel/src/main.zig -lc -lsqlite3 -OReleaseSafe -femit-bin=out/ugwo-kernel

# Stage 2: Compile pure Elm 0.19.1 bundle
FROM debian:trixie-slim AS elm-builder
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl ca-certificates gzip \
  && curl -fsSL https://github.com/elm/compiler/releases/download/0.19.1/binary-for-linux-64-bit.gz -o /tmp/elm.gz \
  && gunzip /tmp/elm.gz && chmod +x /tmp/elm && mv /tmp/elm /usr/local/bin/elm
WORKDIR /ui
COPY ui/elm.json ./elm.json
COPY ui/src ./src
RUN elm make src/Main.elm --optimize --output=/ui/ugwo.js

# Stage 3: Build Gleam OTP 27 erlang-shipment
FROM ghcr.io/gleam-lang/gleam:v1.19.2-erlang-alpine AS gleam-builder
RUN apk add --no-cache build-base
WORKDIR /app
COPY gleam.toml manifest.toml ./
RUN gleam deps download
COPY src ./src
RUN gleam export erlang-shipment

# Stage 4: Production Erlang/OTP 27 + SQLite WAL runtime
FROM debian:trixie-slim AS runtime
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    erlang-nox libsqlite3-0 ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mkdir -p /app/priv/bin /app/priv/static /data

COPY --from=gleam-builder /app/build/erlang-shipment /app/shipment
COPY --from=zig-builder /src/out/ugwo-kernel /app/priv/bin/ugwo-kernel
COPY priv/static/index.html /app/priv/static/index.html
COPY priv/static/styles.css /app/priv/static/styles.css
COPY --from=elm-builder /ui/ugwo.js /app/priv/static/ugwo.js

ENV PORT=3000 \
    UGWO_KERNEL_BIN=/app/priv/bin/ugwo-kernel \
    UGWO_STATIC_DIR=/app/priv/static \
    UGWO_DB_PATH=/data/ugwo.db

EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=4s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:${PORT}/healthz || exit 1

CMD ["/app/shipment/entrypoint.sh", "run"]
