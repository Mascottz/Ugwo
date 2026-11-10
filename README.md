# Ụgwọ : Pan-African Revenue, Scope, Attribution & Fiscal Checkout OS

**Ụgwọ** is a standalone Africa-first revenue, scope-protection, ad-attribution, and tax-fiscalization platform built as a sister product to **FlowMation** (`flowmation.live`) and **Senviok** (`api.senviok.live`).

## Polyglot Systems Architecture

1. **Gleam 1.19 on Erlang/OTP 27 (`src/ugwo.gleam`, `src/ugwo_ffi.erl`)**:
   * Runs a typed OTP Actor (`LedgerActor`) on the BEAM VM to serialize ledger mutations, track supervised operation counts, and serve HTTP routes via `mist` on `0.0.0.0:3000`.
2. **Zig 0.13 Financial & Cryptographic Kernel (`kernel/src/main.zig` → `priv/bin/ugwo-kernel`)**:
   * Compiled in `ReleaseSafe` mode with hardware-checked `i128` minor-unit math (`0-decimal XOF`, `2-decimal NGN/KES/GHS/ZAR/USD`), basis-point VAT and WHT cash splits, E.164 phone normalization, `HmacSha256` `X-Ugwo-Signature` signing, `Sha256` FIRS / eTIMS stamping, and direct C-ABI SQLite WAL persistence (`priv/data/ugwo.db`).
3. **Elm 0.19.1 Operator & Client Vault UI (`ui/src/Main.elm` → `priv/static/ugwo.js`)**:
   * Compiled with `elm make --optimize` for zero runtime exceptions, styled in the **Horse Blood / Aged Wine** brand kit (`BRAND_KIT.md`, `priv/static/styles.css`) with zero generic icons, zero emoji, and zero en/em dashes.

## Four Unified Revenue Surfaces

1. **Pan-African SaaS Subscriptions, Quotas & Non-Expiring Credits**: Local-currency plans (`NGN`, `KES`, `GHS`, `ZAR`, `XOF`, `USD`), `i128` monthly + rollover credit bucket metering, and Senviok WhatsApp dunning with `0`-credit `Stop-on-Paid` suppression.
2. **Agency Scope-Guard, Watermarked Vault & WHT Milestones**: Hard revision caps that convert extra WhatsApp edits into paid change-order add-ons, capability-fragment client portals (`#portal_...`) that redact `download_url` in Zig until net cash clears, and `5%` / `10%` Withholding Tax credit-note splits.
3. **Click-to-WhatsApp → Verified Payment Ad Attribution**: Captures `ctwa_clid` and `ttclid`, blocks fake bank-transfer screenshots, and fires deduplicated Meta CAPI `Purchase` events only on verified ledger settlement.
4. **Real-Time Tax Fiscalization (Nigeria FIRS MBS & Kenya KRA eTIMS)**: Validates TIN / KRA PIN, generates SHA-256 `IRN` / `CU` + `CSID` QR payloads, and buffers invoices in an outage retry queue during HTTP 504 portal timeouts.

## Build & Run Commands

```bash
# 0. Bootstrap toolchains if running on a fresh machine
bash scripts/bootstrap-toolchains.sh

# 1. Compile Zig 0.13 i128 + SQLite WAL kernel
zig build-exe kernel/src/main.zig -lc -lsqlite3 -OReleaseSafe -femit-bin=priv/bin/ugwo-kernel

# 2. Compile Elm 0.19.1 pure MVU bundle
(cd ui && elm make src/Main.elm --optimize --output=../priv/static/ugwo.js)

# 3. Build and start Gleam / Erlang OTP 27 gateway on 0.0.0.0:3000
gleam run
```
