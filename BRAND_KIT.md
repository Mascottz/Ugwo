# Ụgwọ Brand Kit & Polyglot Design Specification

**Brand Name:** **Ụgwọ** (Igbo: payment, settlement, compensation, value due)
**Technical Slug / Prefix:** `ugwo` / `ugw_live_` / `X-Ugwo-Signature`
**Ecosystem Role:** Standalone Front-Office Revenue, Scope, Attribution & Fiscal Checkout OS paired with **FlowMation** (supervised orchestration) and **Senviok** (messaging rail).

---

## 1. Purpose-Built Polyglot Architecture

Every layer of **Ụgwọ** is written in the specialized language best suited to its domain and failure modes:

| Layer | Language & Runtime | Why It Wins for Ụgwọ |
| :--- | :--- | :--- |
| **Orchestration & Supervision** | **Gleam 1.19 on Erlang/OTP 27 BEAM** | Built on the telecom-grade BEAM VM that powers high-concurrency financial switches; typed OTP Actors serialize ledger operations, supervise government-portal 504 circuit-breakers, and serve Mist HTTP endpoints. |
| **Financial & Crypto Kernel** | **Zig 0.13 (`ReleaseSafe` C-ABI)** | Hardware-checked `i128` integer minor-unit arithmetic (`0-decimal XOF`, `2-decimal NGN/KES/GHS/ZAR/USD`), basis-point VAT and WHT splits, native `HmacSha256` webhook signatures, `Sha256` FIRS / eTIMS stamps, and direct C-ABI `sqlite3.h` WAL persistence with zero garbage-collection pauses. |
| **Operator & Client Vault UI** | **Elm 0.19.1 (Pure MVU)** | Pure functional Model-View-Update architecture with exhaustive algebraic sum types and strict JSON decoders; eliminates `undefined is not a function` and produces zero runtime exceptions on checkout and tax portals. |

---

## 2. Color System: Horse Blood & Warm Vellum

The **Ụgwọ** palette pairs deep arterial **Horse Blood / Aged Wine** with **Warm Alabaster Vellum** and **Espresso-Umber Ink** so financial tables, tax stamps, and client portals feel authoritative, high-contrast, and calm.

### Core Brand Ramp (Horse Blood / Aged Wine)
| Token | Hex | Contrast vs `#FFFFFF` | Primary Role |
| :--- | :--- | :--- | :--- |
| `--wine-950` | `#22070B` | `18.6:1` (AAA) | Obsidian Wine: primary left navigation rail, dark code blocks, QR matrix cells |
| `--wine-900` | `#380B12` | `15.4:1` (AAA) | Deep Arterial Wine: elevated rail surfaces and active borders |
| `--wine-800` | `#54101B` | `12.1:1` (AAA) | **Primary Horse Blood**: primary action buttons, `Ụ` sub-dot monogram seal, active navigation state |
| `--wine-700` | `#6E1624` | `9.2:1` (AAA) | Aged Bordeaux: primary button hover and active interactive emphasis |
| `--wine-600` | `#8C1D2F` | `6.6:1` (AA+) | Crimson Wine: focus rings, quota progress fills, active hairline accents |
| `--wine-200` | `#EBD0D5` | N/A | Wine Hairline: tinted badge and banner borders |
| `--wine-100` | `#F9ECEF` | N/A | Blush Vellum: subtle callout backgrounds, capability-token pills |

### Warm Ledger Neutrals
| Token | Hex | Role |
| :--- | :--- | :--- |
| `--bg-canvas` | `#F8F6F4` | Warm Alabaster Vellum: workspace canvas |
| `--bg-surface` | `#FFFFFF` | Crisp Ledger Paper: cards, tables, modals, fiscal invoices |
| `--bg-subtle` | `#F2EEEB` | Stone Vellum: table headers, segmented controls, secondary button hover |
| `--border` | `#E5DFDA` | Warm Hairline: `1px` structural borders |
| `--border-strong` | `#CFC6BF` | Ledger Rule: form input borders and QR frames |
| `--ink-primary` | `#1A1214` | Espresso-Black: primary headings and tabular figures |
| `--ink-secondary` | `#524548` | Warm Umber: supporting labels and metadata |
| `--ink-muted` | `#7A6B6E` | Muted Slate-Rose: column headers and captions |

### Semantic Ledger States
* **Settled / Unlocked / Verified:** Ink `#14532D` on `#EDF6F0` (`#BBD9C5` border)
* **Queued / Past Due / Watermarked:** Ink `#78350F` on `#FDF6E9` (`#F0D9B5` border)
* **Blocked / Fraud Shield / Missing TIN:** Ink `#7F1D1D` on `#FCEEEE` (`#F2C6C6` border)

---

## 3. Typography, Monogram & Iconography Rules

1. **Bespoke Typographic Monogram Only (`Ụ`):**
   * **Ụgwọ** uses **zero generic icons** and **zero emoji** across every screen, modal, badge, and API payload.
   * Visual hierarchy relies on crisp `1px` architectural rules, semantic status pills, tabular numeric alignment (`font-variant-numeric: tabular-nums`), deterministic SVG QR matrices on tax invoices, and the serif sub-dot **`Ụ`** seal set in `#FAF6F5` over `#54101B` Horse Blood.
2. **Font Stack:**
   * **UI & Headings:** `-apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, sans-serif` (`-0.02em` tight display tracking).
   * **Editorial Monogram Seal:** `Georgia, "Iowan Old Style", "Times New Roman", serif` (preserves crisp sub-dot legibility on `Ụ` and `ọ`).
   * **Hashes, Click IDs, TINs & Signatures:** `ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace`.

---

## 4. Strict Punctuation & Editorial Style Guide

1. **No En Dashes or Em Dashes:** Never use en dashes or em dashes anywhere in UI labels, notifications, documentation, or JSON strings.
2. **Contextual Connectors:**
   * Use colons (`:`) for labels, ratios, and key-value pairings (`1 : SaaS Billing`, `State: Active`).
   * Use semicolons (`;`), commas (`,`), or periods (`.`) to join or separate clauses cleanly.
   * Use directional arrows (`→`) exclusively for causal or pipeline transitions (`Click-to-WhatsApp → Verified Payment`, `Ụgwọ → FlowMation`).
3. **Hyphenation Rule:** Use the standard ASCII hyphen (`-`) **strictly inside hyphenated compound words** (`Africa-first`, `non-card`, `zero-float`, `out-of-scope`, `Stop-on-Paid`, `real-time`, `server-side`, `0-decimal`, `2-decimal`), never with surrounding spaces as a sentence separator.
