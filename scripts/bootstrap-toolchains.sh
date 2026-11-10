#!/usr/bin/env bash
set -euo pipefail

# Bootstrap Gleam (BEAM), Zig 0.13, Elm 0.19.1, and SQLite C headers on Debian/Ubuntu.
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  erlang-nox erlang-dev rebar3 sqlite3 libsqlite3-dev curl xz-utils

if ! command -v zig >/dev/null 2>&1; then
  curl -fsSL https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz -o /tmp/zig.tar.xz
  sudo mkdir -p /opt/zig
  sudo tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
  sudo ln -sf /opt/zig/zig /usr/local/bin/zig
  rm -f /tmp/zig.tar.xz
fi

if ! command -v elm >/dev/null 2>&1; then
  curl -fsSL https://github.com/elm/compiler/releases/download/0.19.1/binary-for-linux-64-bit.gz -o /tmp/elm.gz
  gunzip -f /tmp/elm.gz
  chmod +x /tmp/elm
  sudo mv /tmp/elm /usr/local/bin/elm
fi

if ! command -v gleam >/dev/null 2>&1; then
  LATEST_URL=$(python3 -c "import urllib.request, json; r = json.loads(urllib.request.urlopen('https://api.github.com/repos/gleam-lang/gleam/releases/latest').read()); print([a['browser_download_url'] for a in r['assets'] if 'x86_64-unknown-linux-musl.tar.gz' in a['name']][0])")
  curl -fsSL "$LATEST_URL" -o /tmp/gleam.tar.gz
  sudo tar -xzf /tmp/gleam.tar.gz -C /usr/local/bin gleam
  rm -f /tmp/gleam.tar.gz
fi

echo "Toolchains ready:"
erl -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().' -noshell
gleam --version
zig version
elm --version
