const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const CurrencySpec = struct {
    code: []const u8,
    decimals: u8,
    symbol: []const u8,
};

pub fn getCurrencySpec(code: []const u8) CurrencySpec {
    if (std.ascii.eqlIgnoreCase(code, "XOF")) return .{ .code = "XOF", .decimals = 0, .symbol = "CFA " };
    if (std.ascii.eqlIgnoreCase(code, "KES")) return .{ .code = "KES", .decimals = 2, .symbol = "KSh " };
    if (std.ascii.eqlIgnoreCase(code, "GHS")) return .{ .code = "GHS", .decimals = 2, .symbol = "GH\xc2\xa2" };
    if (std.ascii.eqlIgnoreCase(code, "ZAR")) return .{ .code = "ZAR", .decimals = 2, .symbol = "R " };
    if (std.ascii.eqlIgnoreCase(code, "USD")) return .{ .code = "USD", .decimals = 2, .symbol = "$" };
    return .{ .code = "NGN", .decimals = 2, .symbol = "\xe2\x82\xa6" };
}

/// Zero-float i128 minor-unit formatter with comma grouping and exact currency exponent.
pub fn formatMoneyAlloc(alloc: std.mem.Allocator, amount_minor: i128, currency: []const u8) ![]u8 {
    const spec = getCurrencySpec(currency);
    const neg = amount_minor < 0;
    const abs_val: u128 = @intCast(if (neg) -amount_minor else amount_minor);

    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();

    if (neg) try out.append('-');
    try out.appendSlice(spec.symbol);

    const factor: u128 = if (spec.decimals == 0) 1 else 100;
    const whole: u128 = abs_val / factor;
    const frac: u128 = abs_val % factor;

    var digits_buf: [64]u8 = undefined;
    const whole_str = try std.fmt.bufPrint(&digits_buf, "{d}", .{whole});

    for (whole_str, 0..) |ch, idx| {
        if (idx > 0 and ((whole_str.len - idx) % 3 == 0)) {
            try out.append(',');
        }
        try out.append(ch);
    }

    if (spec.decimals == 2) {
        var frac_buf: [8]u8 = undefined;
        const frac_str = try std.fmt.bufPrint(&frac_buf, ".{d:0>2}", .{@as(u64, @intCast(frac))});
        try out.appendSlice(frac_str);
    }

    return out.toOwnedSlice();
}

pub const TaxSplit = struct {
    subtotal_minor: i128,
    vat_minor: i128,
    gross_minor: i128,
    wht_minor: i128,
    net_cash_minor: i128,
};

/// Overflow-checked i128 basis-point VAT and WHT split (never touches IEEE-754 floats).
pub fn computeTaxAndWht(subtotal_minor: i128, vat_bps: i128, wht_bps: i128) !TaxSplit {
    const vat_num = try std.math.mul(i128, subtotal_minor, vat_bps);
    const vat = @divTrunc(try std.math.add(i128, vat_num, 5000), 10000);

    const wht_num = try std.math.mul(i128, subtotal_minor, wht_bps);
    const wht = @divTrunc(try std.math.add(i128, wht_num, 5000), 10000);

    const gross = try std.math.add(i128, subtotal_minor, vat);
    const net_cash = try std.math.sub(i128, gross, wht);

    return .{
        .subtotal_minor = subtotal_minor,
        .vat_minor = vat,
        .gross_minor = gross,
        .wht_minor = wht,
        .net_cash_minor = net_cash,
    };
}

pub fn normalizeE164(alloc: std.mem.Allocator, raw: []const u8, country: []const u8) ![]u8 {
    var digits = std.ArrayList(u8).init(alloc);
    defer digits.deinit();

    var has_plus = false;
    for (raw) |ch| {
        if (ch == '+' and digits.items.len == 0) {
            has_plus = true;
        } else if (ch >= '0' and ch <= '9') {
            try digits.append(ch);
        }
    }
    if (has_plus and digits.items.len >= 9) {
        return std.fmt.allocPrint(alloc, "+{s}", .{digits.items});
    }

    const dial = if (std.ascii.eqlIgnoreCase(country, "KE"))
        "254"
    else if (std.ascii.eqlIgnoreCase(country, "GH"))
        "233"
    else if (std.ascii.eqlIgnoreCase(country, "CI"))
        "225"
    else if (std.ascii.eqlIgnoreCase(country, "ZA"))
        "27"
    else
        "234";

    var body = digits.items;
    if (std.mem.startsWith(u8, body, dial)) {
        return std.fmt.allocPrint(alloc, "+{s}", .{body});
    }
    if (body.len > 0 and body[0] == '0') {
        body = body[1..];
    }
    return std.fmt.allocPrint(alloc, "+{s}{s}", .{ dial, body });
}

pub fn signWebhookHmac(alloc: std.mem.Allocator, secret: []const u8, payload_json: []const u8) ![]u8 {
    const ts: i64 = std.time.timestamp();
    const msg = try std.fmt.allocPrint(alloc, "{d}.{s}", .{ ts, payload_json });
    defer alloc.free(msg);

    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, msg, secret);
    const hex = std.fmt.bytesToHex(mac, .lower);
    return std.fmt.allocPrint(alloc, "t={d},sha256={s}", .{ ts, &hex });
}

pub const FiscalStamp = struct {
    irn: []u8,
    csid: []u8,
    qr: []u8,
};

pub fn computeFiscalStamp(
    alloc: std.mem.Allocator,
    authority: []const u8,
    seller_tin: []const u8,
    buyer_tin: []const u8,
    invoice_num: []const u8,
    gross_minor: i128,
    currency: []const u8,
) !FiscalStamp {
    const ts: u64 = @intCast(std.time.timestamp());
    var rand_bytes: [3]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    const suffix = std.fmt.bytesToHex(rand_bytes, .upper);

    const prefix = if (std.mem.eql(u8, authority, "KRA_ETIMS_KE")) "KRA-ETIMS" else "FIRS-IRN";
    const irn = try std.fmt.allocPrint(alloc, "{s}-20261110-{s}", .{ prefix, &suffix });

    const canonical = try std.fmt.allocPrint(
        alloc,
        "{s}|{s}|{s}|{s}|{s}|{d}|{s}|{d}",
        .{ authority, irn, seller_tin, buyer_tin, invoice_num, gross_minor, currency, ts },
    );
    defer alloc.free(canonical);

    var digest: [32]u8 = undefined;
    Sha256.hash(canonical, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .upper);

    const csid = try std.fmt.allocPrint(alloc, "CSID-{s}", .{digest_hex[0..16]});
    const qr = try std.fmt.allocPrint(
        alloc,
        "https://verify.ugwo.live/fiscal/{s}?csid={s}&tin={s}&amt={d}&cur={s}",
        .{ irn, digest_hex[0..16], seller_tin, gross_minor, currency },
    );

    return .{ .irn = irn, .csid = csid, .qr = qr };
}

fn appendJsonEscaped(out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => {
                if (ch < 0x20) {
                    var buf: [6]u8 = undefined;
                    const esc = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{@as(u16, ch)});
                    try out.appendSlice(esc);
                } else {
                    try out.append(ch);
                }
            },
        }
    }
    try out.append('"');
}

fn execSql(db: *c.sqlite3, sql: [:0]const u8) !void {
    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, sql.ptr, null, null, &err_msg);
    if (rc != c.SQLITE_OK) {
        if (err_msg != null) {
            std.debug.print("SQLite error: {s}\n", .{std.mem.span(err_msg)});
            c.sqlite3_free(err_msg);
        }
        return error.SqliteExecFailed;
    }
}

fn colText(stmt: *c.sqlite3_stmt, idx: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, idx);
    if (ptr == null) return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, idx));
    return ptr[0..len];
}

fn colInt(stmt: *c.sqlite3_stmt, idx: c_int) i64 {
    return c.sqlite3_column_int64(stmt, idx);
}

fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, val: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, idx, val.ptr, @intCast(val.len), c.SQLITE_TRANSIENT);
}

fn randomHexId(alloc: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var b: [4]u8 = undefined;
    std.crypto.random.bytes(&b);
    const h = std.fmt.bytesToHex(b, .lower);
    return std.fmt.allocPrint(alloc, "{s}_{s}", .{ prefix, &h });
}

fn nowIsoAlloc(alloc: std.mem.Allocator) ![]u8 {
    const ts: u64 = @intCast(std.time.timestamp());
    const es = std.time.epoch.EpochSeconds{ .secs = ts };
    const day_seconds = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(
        alloc,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn emitOutboxEvent(
    alloc: std.mem.Allocator,
    db: *c.sqlite3,
    target: []const u8,
    event_type: []const u8,
    dest: []const u8,
    status: []const u8,
    credits: i64,
    sig: []const u8,
    payload_json: []const u8,
) !void {
    const id = try randomHexId(alloc, "evt");
    defer alloc.free(id);
    const ts = try nowIsoAlloc(alloc);
    defer alloc.free(ts);

    const sql =
        "INSERT INTO outbox_events (id, target, event_type, recipient_or_endpoint, status, credits_used, signature_header, payload_json, created_at) " ++
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt.?);

    bindText(stmt.?, 1, id);
    bindText(stmt.?, 2, target);
    bindText(stmt.?, 3, event_type);
    bindText(stmt.?, 4, dest);
    bindText(stmt.?, 5, status);
    _ = c.sqlite3_bind_int64(stmt.?, 6, credits);
    bindText(stmt.?, 7, sig);
    bindText(stmt.?, 8, payload_json);
    bindText(stmt.?, 9, ts);
    if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) return error.StepFailed;
}

fn emitFlowMationHook(alloc: std.mem.Allocator, db: *c.sqlite3, event_type: []const u8, inner_json: []const u8) ![]u8 {
    var stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT flowmation_hook_url, flowmation_hook_secret FROM workspace_settings LIMIT 1;", -1, &stmt, null);
    defer _ = c.sqlite3_finalize(stmt.?);
    _ = c.sqlite3_step(stmt.?);
    const url = try alloc.dupe(u8, colText(stmt.?, 0));
    defer alloc.free(url);
    const secret = try alloc.dupe(u8, colText(stmt.?, 1));
    defer alloc.free(secret);

    const ts = try nowIsoAlloc(alloc);
    defer alloc.free(ts);

    const envelope = try std.fmt.allocPrint(
        alloc,
        "{{\"event\":\"{s}\",\"workspace\":\"mastech-ops\",\"emitted_at\":\"{s}\",\"data\":{s}}}",
        .{ event_type, ts, inner_json },
    );
    defer alloc.free(envelope);

    const sig = try signWebhookHmac(alloc, secret, envelope);
    try emitOutboxEvent(alloc, db, "flowmation_webhook", event_type, url, "delivered", 0, sig, envelope);
    return sig;
}

const IssuedFiscal = struct {
    invoice_number: []u8,
    fiscal_status: []u8,
    irn: []u8,
};

fn issueFiscalInvoice(
    alloc: std.mem.Allocator,
    db: *c.sqlite3,
    source_kind: []const u8,
    source_ref: []const u8,
    buyer_name: []const u8,
    buyer_tin: []const u8,
    currency: []const u8,
    subtotal_minor: i128,
    vat_minor: i128,
    wht_minor: i128,
    payable_minor: i128,
) !IssuedFiscal {
    var ws_stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT seller_tin, gov_portal_outage_sim FROM workspace_settings LIMIT 1;", -1, &ws_stmt, null);
    defer _ = c.sqlite3_finalize(ws_stmt.?);
    _ = c.sqlite3_step(ws_stmt.?);
    const seller_tin = try alloc.dupe(u8, colText(ws_stmt.?, 0));
    defer alloc.free(seller_tin);
    const outage = colInt(ws_stmt.?, 1);

    var cnt_stmt: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM fiscal_invoices;", -1, &cnt_stmt, null);
    defer _ = c.sqlite3_finalize(cnt_stmt.?);
    _ = c.sqlite3_step(cnt_stmt.?);
    const count = colInt(cnt_stmt.?, 0);

    const seq: u64 = @intCast(if (count >= 0) 41 + count else 41);
    const inv_num = try std.fmt.allocPrint(alloc, "INV-2026-{d:0>4}", .{seq});
    const authority = if (std.ascii.eqlIgnoreCase(currency, "KES")) "KRA_ETIMS_KE" else "FIRS_MBS_NG";
    const id = try randomHexId(alloc, "fisc");
    defer alloc.free(id);
    const ts = try nowIsoAlloc(alloc);
    defer alloc.free(ts);

    var status: []u8 = undefined;
    var irn: []u8 = undefined;
    var csid: []u8 = undefined;
    var qr: []u8 = undefined;
    var err_detail: []u8 = undefined;
    var retries: i64 = 0;

    if (buyer_tin.len < 5) {
        status = try alloc.dupe(u8, "tin_error");
        irn = try alloc.dupe(u8, "");
        csid = try alloc.dupe(u8, "");
        qr = try alloc.dupe(u8, "");
        err_detail = try std.fmt.allocPrint(alloc, "Buyer TIN or PIN missing for {s} clearance.", .{authority});
    } else if (outage == 1) {
        status = try alloc.dupe(u8, "queued_gov_outage");
        irn = try alloc.dupe(u8, "");
        csid = try alloc.dupe(u8, "");
        qr = try alloc.dupe(u8, "");
        err_detail = try std.fmt.allocPrint(alloc, "{s} upstream HTTP 504 timeout: queued safely in local buffer; checkout unaffected.", .{authority});
        retries = 1;
    } else {
        status = try alloc.dupe(u8, "stamped");
        const stamp = try computeFiscalStamp(alloc, authority, seller_tin, buyer_tin, inv_num, subtotal_minor + vat_minor, currency);
        irn = stamp.irn;
        csid = stamp.csid;
        qr = stamp.qr;
        err_detail = try alloc.dupe(u8, "");
    }
    defer alloc.free(csid);
    defer alloc.free(qr);
    defer alloc.free(err_detail);

    const sql =
        "INSERT INTO fiscal_invoices (id, invoice_number, source_kind, source_ref, buyer_name, buyer_tin, authority, currency, subtotal_minor, vat_minor, wht_minor, payable_cash_minor, fiscal_status, irn_or_cu, csid_hash, qr_payload, retry_count, error_detail, created_at) " ++
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19);";
    var ins: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &ins, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(ins.?);

    bindText(ins.?, 1, id);
    bindText(ins.?, 2, inv_num);
    bindText(ins.?, 3, source_kind);
    bindText(ins.?, 4, source_ref);
    bindText(ins.?, 5, buyer_name);
    bindText(ins.?, 6, buyer_tin);
    bindText(ins.?, 7, authority);
    bindText(ins.?, 8, currency);
    _ = c.sqlite3_bind_int64(ins.?, 9, @intCast(subtotal_minor));
    _ = c.sqlite3_bind_int64(ins.?, 10, @intCast(vat_minor));
    _ = c.sqlite3_bind_int64(ins.?, 11, @intCast(wht_minor));
    _ = c.sqlite3_bind_int64(ins.?, 12, @intCast(payable_minor));
    bindText(ins.?, 13, status);
    bindText(ins.?, 14, irn);
    bindText(ins.?, 15, csid);
    bindText(ins.?, 16, qr);
    _ = c.sqlite3_bind_int64(ins.?, 17, retries);
    bindText(ins.?, 18, err_detail);
    bindText(ins.?, 19, ts);
    if (c.sqlite3_step(ins.?) != c.SQLITE_DONE) return error.StepFailed;

    return .{ .invoice_number = inv_num, .fiscal_status = status, .irn = irn };
}

fn initSchemaAndSeed(alloc: std.mem.Allocator, db: *c.sqlite3) !void {
    try execSql(db, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;");
    const schema =
        \\CREATE TABLE IF NOT EXISTS workspace_settings (
        \\  id TEXT PRIMARY KEY, slug TEXT NOT NULL, name TEXT NOT NULL,
        \\  default_currency TEXT NOT NULL, seller_tin TEXT NOT NULL,
        \\  gov_portal_outage_sim INTEGER NOT NULL DEFAULT 0,
        \\  senviok_sender_id TEXT NOT NULL, flowmation_hook_url TEXT NOT NULL,
        \\  flowmation_hook_secret TEXT NOT NULL, meta_pixel_id TEXT NOT NULL, api_key TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS plans (
        \\  id TEXT PRIMARY KEY, code TEXT NOT NULL, name TEXT NOT NULL,
        \\  kind TEXT NOT NULL, billing_interval TEXT NOT NULL,
        \\  ngn_minor INTEGER NOT NULL, kes_minor INTEGER NOT NULL, ghs_minor INTEGER NOT NULL,
        \\  zar_minor INTEGER NOT NULL, xof_minor INTEGER NOT NULL, usd_minor INTEGER NOT NULL,
        \\  included_units INTEGER NOT NULL, included_credits INTEGER NOT NULL, rails_label TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS subscriptions (
        \\  id TEXT PRIMARY KEY, plan_id TEXT NOT NULL, customer_name TEXT NOT NULL,
        \\  customer_company TEXT NOT NULL, customer_phone TEXT NOT NULL, buyer_tin TEXT NOT NULL,
        \\  currency TEXT NOT NULL, amount_minor INTEGER NOT NULL, preferred_rail TEXT NOT NULL,
        \\  rail_detail TEXT NOT NULL, status TEXT NOT NULL, units_limit INTEGER NOT NULL,
        \\  units_used INTEGER NOT NULL, monthly_credits_left INTEGER NOT NULL,
        \\  rollover_credits INTEGER NOT NULL, dunning_stage TEXT NOT NULL,
        \\  portal_token TEXT NOT NULL, created_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS agency_projects (
        \\  id TEXT PRIMARY KEY, title TEXT NOT NULL, client_name TEXT NOT NULL,
        \\  client_company TEXT NOT NULL, client_phone TEXT NOT NULL, buyer_tin TEXT NOT NULL,
        \\  currency TEXT NOT NULL, subtotal_minor INTEGER NOT NULL, vat_rate_bps INTEGER NOT NULL,
        \\  wht_rate_bps INTEGER NOT NULL, vat_minor INTEGER NOT NULL, gross_invoice_minor INTEGER NOT NULL,
        \\  wht_credit_note_minor INTEGER NOT NULL, net_cash_expected_minor INTEGER NOT NULL,
        \\  cash_paid_minor INTEGER NOT NULL, wht_cert_status TEXT NOT NULL,
        \\  revisions_included INTEGER NOT NULL, revisions_used INTEGER NOT NULL,
        \\  extra_revision_fee_minor INTEGER NOT NULL, pending_addon_minor INTEGER NOT NULL,
        \\  vault_unlocked INTEGER NOT NULL, payment_rail TEXT NOT NULL,
        \\  portal_token TEXT NOT NULL, created_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS project_deliverables (
        \\  id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
        \\  watermarked_preview TEXT NOT NULL, unlocked_secret_url TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS ad_leads (
        \\  id TEXT PRIMARY KEY, platform TEXT NOT NULL, campaign_name TEXT NOT NULL,
        \\  creative_name TEXT NOT NULL, click_id TEXT NOT NULL, ad_spend_minor INTEGER NOT NULL,
        \\  customer_name TEXT NOT NULL, customer_phone TEXT NOT NULL, whatsapp_first_msg TEXT NOT NULL,
        \\  currency TEXT NOT NULL, expected_amount_minor INTEGER NOT NULL,
        \\  verified_paid_minor INTEGER NOT NULL, payment_rail TEXT NOT NULL,
        \\  fake_screenshots_blocked INTEGER NOT NULL, capi_status TEXT NOT NULL,
        \\  capi_event_id TEXT NOT NULL, created_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS fiscal_invoices (
        \\  id TEXT PRIMARY KEY, invoice_number TEXT NOT NULL, source_kind TEXT NOT NULL,
        \\  source_ref TEXT NOT NULL, buyer_name TEXT NOT NULL, buyer_tin TEXT NOT NULL,
        \\  authority TEXT NOT NULL, currency TEXT NOT NULL, subtotal_minor INTEGER NOT NULL,
        \\  vat_minor INTEGER NOT NULL, wht_minor INTEGER NOT NULL, payable_cash_minor INTEGER NOT NULL,
        \\  fiscal_status TEXT NOT NULL, irn_or_cu TEXT NOT NULL, csid_hash TEXT NOT NULL,
        \\  qr_payload TEXT NOT NULL, retry_count INTEGER NOT NULL, error_detail TEXT NOT NULL,
        \\  created_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS outbox_events (
        \\  id TEXT PRIMARY KEY, target TEXT NOT NULL, event_type TEXT NOT NULL,
        \\  recipient_or_endpoint TEXT NOT NULL, status TEXT NOT NULL, credits_used INTEGER NOT NULL,
        \\  signature_header TEXT NOT NULL, payload_json TEXT NOT NULL, created_at TEXT NOT NULL
        \\);
    ;
    try execSql(db, schema);

    var chk: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM workspace_settings;", -1, &chk, null);
    defer _ = c.sqlite3_finalize(chk.?);
    _ = c.sqlite3_step(chk.?);
    if (colInt(chk.?, 0) > 0) return;

    const seed_sql =
        \\INSERT INTO workspace_settings VALUES (
        \\  'ws_01', 'mastech-ops', 'Ụgwọ Primary Ledger', 'NGN', 'TIN-20948172-0001', 0,
        \\  'Ugwo', 'https://flowmation.live/hooks/mastech-rev/ugwo',
        \\  'whsec_ugw_9a82d4c0e71b4f3a8b21c6e5091f44aa', 'META-PX-884920193',
        \\  'ugw_live_8f41c92a7b0e4d12a9813f6e'
        \\);
        \\INSERT INTO plans VALUES
        \\  ('plan_starter', 'starter_monthly', 'Starter SaaS Plan', 'subscription', 'monthly', 1500000, 160000, 18000, 22000, 7500, 1200, 50000, 500, 'Monnify VA, Paystack, M-Pesa, pawaPay, FedaPay'),
        \\  ('plan_growth', 'growth_monthly', 'Growth Multi-Rail Plan', 'subscription', 'monthly', 4000000, 420000, 48000, 59000, 19500, 3200, 250000, 2500, 'Monnify VA, Paystack, M-Pesa, pawaPay, FedaPay, Yoco'),
        \\  ('pack_2500', 'rollover_2500', '2,500 Non-Expiring Credits', 'credit_pack', 'one_time', 2500000, 260000, 30000, 37000, 12500, 2000, 0, 2500, 'All Local Transfer & Mobile Money Rails');
        \\INSERT INTO subscriptions VALUES
        \\  ('sub_ng_01', 'plan_growth', 'Tunde Adeyemi', 'KoboTrack Logistics Ltd', '+2348034192831', 'TIN-31094821-0001', 'NGN', 4000000, 'monnify_va', 'Monnify Dedicated VA: 8491023319 (Wema)', 'active', 250000, 168400, 420, 2500, 'none', 'cap_sub_tunde_91a8f2', '2026-11-08T09:15:00Z'),
        \\  ('sub_ke_02', 'plan_growth', 'Wanjiku Mwangi', 'Savannah Health Tech', '+254712908341', 'P051882910M', 'KES', 420000, 'mpesa_stk', 'M-Pesa Daraja STK / PayBill 409821', 'past_due', 250000, 241900, 85, 500, 'd_plus_3_whatsapp', 'cap_sub_wanjiku_73c4b1', '2026-11-07T14:20:00Z'),
        \\  ('sub_ci_03', 'plan_starter', 'Kouame NGuessan', 'Lagune Express SARL', '+2250708441920', 'CI-NCC-9928174', 'XOF', 7500, 'fedapay_xof', 'FedaPay Orange Money: +225 07 08 44 19 20', 'active', 50000, 19450, 310, 0, 'none', 'cap_sub_kouame_55e9d0', '2026-11-09T11:05:00Z'),
        \\  ('sub_gh_04', 'plan_starter', 'Kwame Boateng', 'Osu Cloud Studio', '+233244918273', 'GHA-TIN-0049182', 'GHS', 18000, 'pawapay_momo', 'pawaPay MTN MoMo: +233 24 491 8273', 'past_due', 50000, 48900, 12, 0, 'd_0_due', 'cap_sub_kwame_18f2a9', '2026-11-09T16:40:00Z');
        \\INSERT INTO agency_projects VALUES
        \\  ('proj_ng_01', 'Mobile Banking App Redesign & Next.js Web Portal', 'Chidinma Okafor', 'Crestline Microfinance Bank', '+2348091123409', 'TIN-10492811-0002', 'NGN', 180000000, 750, 500, 13500000, 193500000, 9000000, 184500000, 92250000, 'pending_cert', 3, 3, 15000000, 0, 0, 'Paystack Split Bank Transfer', 'portal_crestline_882a9c', '2026-11-05T10:00:00Z'),
        \\  ('proj_ke_02', 'Q4 Click-to-WhatsApp Ad Funnel & Brand Motion Kit', 'David Mutua', 'Kilimani Solar Homes', '+254722891044', 'P051399182L', 'KES', 35000000, 1600, 500, 5600000, 40600000, 1750000, 38850000, 38850000, 'verified', 2, 1, 2500000, 0, 1, 'M-Pesa Daraja PayBill', 'portal_kilimani_41d7e0', '2026-11-03T08:30:00Z');
        \\INSERT INTO project_deliverables VALUES
        \\  ('del_01', 'proj_ng_01', 'Figma Design System & 48 Mobile Screens (v3 Final)', 'WATERMARKED PREVIEW ONLY: View-only canvas at 72dpi; export disabled until balance clears.', 'https://figma.com/file/crestline-mfb-prod-master?key=UNLK-99481-FULL-EDIT'),
        \\  ('del_02', 'proj_ng_01', 'Production Next.js + Paystack Onboarding Repo', 'LOCKED STAGING PREVIEW: https://preview-watermarked.ugwo.live/crestline', 'https://github.com/afriscale-agency/crestline-portal-release/releases/tag/v1.0.0-signed'),
        \\  ('del_03', 'proj_ke_02', '12x High-Converting Reels Ad Masters (4K ProRes + Captions)', 'Watermarked 480p review reel', 'https://cdn.ugwo.live/vault/kilimani-solar-4k-masters-unlocked.zip');
        \\INSERT INTO ad_leads VALUES
        \\  ('lead_01', 'meta_ctwa', 'Lagos_SME_Solar_Inverter_Q4', 'Reel_04_NoGenNoise_PidginHook', 'ctwa_clid_EAa981fK29xLmP02', 18500000, 'Emeka Nwosu', '+2348023310984', 'Hi, saw your Instagram video on the 5kVA lithium inverter bundle. Can I pay by bank transfer?', 'NGN', 145000000, 145000000, 'Monnify Instant Transfer', 0, 'capi_purchase_fired', 'evt_meta_capi_99201a', '2026-11-09T13:10:00Z'),
        \\  ('lead_02', 'meta_ctwa', 'Lagos_SME_Solar_Inverter_Q4', 'Reel_04_NoGenNoise_PidginHook', 'ctwa_clid_EAa774bN10zQwR88', 0, 'Sadiq Bello', '+2348160092811', 'Good afternoon, sending transfer receipt screenshot now for 3.5kVA package, please dispatch rider.', 'NGN', 98000000, 0, 'Monnify Instant Transfer', 1, 'awaiting_settlement', '', '2026-11-10T08:45:00Z'),
        \\  ('lead_03', 'tiktok_messaging', 'Nairobi_Clinic_Skincare_Promo', 'UGC_Creator_Amina_Swahili', 'ttclid_KE9918273645abc', 4500000, 'Faith Njeri', '+254701448291', 'Hey, want to book the 3-session Hydrafacial bundle via M-Pesa.', 'KES', 2850000, 0, 'M-Pesa Daraja STK Push', 0, 'awaiting_settlement', '', '2026-11-10T09:50:00Z');
    ;
    try execSql(db, seed_sql);

    const s1 = try issueFiscalInvoice(alloc, db, "subscription", "sub_ng_01", "KoboTrack Logistics Ltd", "TIN-31094821-0001", "NGN", 3720930, 279070, 0, 4000000);
    alloc.free(s1.invoice_number);
    alloc.free(s1.fiscal_status);
    alloc.free(s1.irn);

    const s2 = try issueFiscalInvoice(alloc, db, "agency_milestone", "proj_ke_02", "Kilimani Solar Homes", "P051399182L", "KES", 35000000, 5600000, 1750000, 38850000);
    alloc.free(s2.invoice_number);
    alloc.free(s2.fiscal_status);
    alloc.free(s2.irn);

    try execSql(db,
        \\INSERT INTO fiscal_invoices VALUES (
        \\  'fisc_seed_q', 'INV-2026-0043', 'ad_commerce', 'lead_01', 'Emeka Nwosu Ventures',
        \\  'TIN-55819204-0001', 'FIRS_MBS_NG', 'NGN', 134883721, 10116279, 0, 145000000,
        \\  'queued_gov_outage', '', '', '', 2,
        \\  'FIRS MBS upstream HTTP 504 Gateway Timeout during month-end filing peak: queued safely without blocking buyer receipt.',
        \\  '2026-11-10T09:15:00Z'
        \\);
    );

    const hook_sig = try emitFlowMationHook(alloc, db, "attribution.purchase.verified", "{\"lead_id\":\"lead_01\",\"currency\":\"NGN\",\"amount_minor\":145000000,\"capi_event_id\":\"evt_meta_capi_99201a\"}");
    alloc.free(hook_sig);
    try emitOutboxEvent(alloc, db, "senviok_whatsapp", "dunning.scheduled_followup", "+2348034192831", "suppressed_stop_on_paid", 0, "stop_on_paid_guard", "{\"subscription_id\":\"sub_ng_01\",\"guard\":\"Already active via Monnify VA; 0 credits charged.\"}");
}

fn dumpFullStateJson(alloc: std.mem.Allocator, db: *c.sqlite3, out: *std.ArrayList(u8)) !void {
    try out.appendSlice("{\"workspace\":{");

    var ws: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT slug, name, seller_tin, gov_portal_outage_sim, senviok_sender_id, flowmation_hook_url, api_key FROM workspace_settings LIMIT 1;", -1, &ws, null);
    defer _ = c.sqlite3_finalize(ws.?);
    _ = c.sqlite3_step(ws.?);

    try out.appendSlice("\"slug\":");
    try appendJsonEscaped(out, colText(ws.?, 0));
    try out.appendSlice(",\"name\":");
    try appendJsonEscaped(out, colText(ws.?, 1));
    try out.appendSlice(",\"seller_tin\":");
    try appendJsonEscaped(out, colText(ws.?, 2));
    try out.appendSlice(",\"gov_portal_outage_sim\":");
    try out.appendSlice(if (colInt(ws.?, 3) == 1) "true" else "false");
    try out.appendSlice(",\"senviok_sender_id\":");
    try appendJsonEscaped(out, colText(ws.?, 4));
    try out.appendSlice(",\"flowmation_hook_url\":");
    try appendJsonEscaped(out, colText(ws.?, 5));
    try out.appendSlice(",\"api_key\":");
    try appendJsonEscaped(out, colText(ws.?, 6));
    try out.appendSlice("},");

    // Plans
    try out.appendSlice("\"plans\":[");
    var ps: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT id, name, kind, billing_interval, ngn_minor, kes_minor, ghs_minor, zar_minor, xof_minor, usd_minor, included_units, included_credits, rails_label FROM plans;", -1, &ps, null);
    defer _ = c.sqlite3_finalize(ps.?);
    var first_p = true;
    while (c.sqlite3_step(ps.?) == c.SQLITE_ROW) {
        if (!first_p) try out.append(',');
        first_p = false;

        const ngn_f = try formatMoneyAlloc(alloc, colInt(ps.?, 4), "NGN");
        defer alloc.free(ngn_f);
        const kes_f = try formatMoneyAlloc(alloc, colInt(ps.?, 5), "KES");
        defer alloc.free(kes_f);
        const ghs_f = try formatMoneyAlloc(alloc, colInt(ps.?, 6), "GHS");
        defer alloc.free(ghs_f);
        const zar_f = try formatMoneyAlloc(alloc, colInt(ps.?, 7), "ZAR");
        defer alloc.free(zar_f);
        const xof_f = try formatMoneyAlloc(alloc, colInt(ps.?, 8), "XOF");
        defer alloc.free(xof_f);
        const usd_f = try formatMoneyAlloc(alloc, colInt(ps.?, 9), "USD");
        defer alloc.free(usd_f);

        try out.appendSlice("{\"id\":");
        try appendJsonEscaped(out, colText(ps.?, 0));
        try out.appendSlice(",\"name\":");
        try appendJsonEscaped(out, colText(ps.?, 1));
        try out.appendSlice(",\"kind\":");
        try appendJsonEscaped(out, colText(ps.?, 2));
        try out.appendSlice(",\"billing_interval\":");
        try appendJsonEscaped(out, colText(ps.?, 3));
        try out.appendSlice(",\"ngn_fmt\":");
        try appendJsonEscaped(out, ngn_f);
        try out.appendSlice(",\"kes_fmt\":");
        try appendJsonEscaped(out, kes_f);
        try out.appendSlice(",\"ghs_fmt\":");
        try appendJsonEscaped(out, ghs_f);
        try out.appendSlice(",\"zar_fmt\":");
        try appendJsonEscaped(out, zar_f);
        try out.appendSlice(",\"xof_fmt\":");
        try appendJsonEscaped(out, xof_f);
        try out.appendSlice(",\"usd_fmt\":");
        try appendJsonEscaped(out, usd_f);

        const nums = try std.fmt.allocPrint(alloc, ",\"included_units\":{d},\"included_credits\":{d},\"rails_label\":", .{ colInt(ps.?, 10), colInt(ps.?, 11) });
        defer alloc.free(nums);
        try out.appendSlice(nums);
        try appendJsonEscaped(out, colText(ps.?, 12));
        try out.append('}');
    }
    try out.appendSlice("],");

    // Subscriptions + accumulate ledger totals per currency
    const cur_codes = [_][]const u8{ "NGN", "KES", "GHS", "ZAR", "XOF", "USD" };
    var totals = [_]i128{ 0, 0, 0, 0, 0, 0 };

    try out.appendSlice("\"subscriptions\":[");
    var ss: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT id, plan_id, customer_name, customer_company, customer_phone, currency, amount_minor, rail_detail, status, units_limit, units_used, monthly_credits_left, rollover_credits, dunning_stage, portal_token FROM subscriptions ORDER BY created_at DESC;", -1, &ss, null);
    defer _ = c.sqlite3_finalize(ss.?);
    var first_s = true;
    while (c.sqlite3_step(ss.?) == c.SQLITE_ROW) {
        if (!first_s) try out.append(',');
        first_s = false;

        const cur = colText(ss.?, 5);
        const amt: i128 = colInt(ss.?, 6);
        const st = colText(ss.?, 8);
        if (std.mem.eql(u8, st, "active")) {
            for (cur_codes, 0..) |cc, idx| {
                if (std.ascii.eqlIgnoreCase(cur, cc)) totals[idx] += amt;
            }
        }
        const amt_fmt = try formatMoneyAlloc(alloc, amt, cur);
        defer alloc.free(amt_fmt);

        try out.appendSlice("{\"id\":");
        try appendJsonEscaped(out, colText(ss.?, 0));
        try out.appendSlice(",\"plan_id\":");
        try appendJsonEscaped(out, colText(ss.?, 1));
        try out.appendSlice(",\"customer_name\":");
        try appendJsonEscaped(out, colText(ss.?, 2));
        try out.appendSlice(",\"customer_company\":");
        try appendJsonEscaped(out, colText(ss.?, 3));
        try out.appendSlice(",\"customer_phone\":");
        try appendJsonEscaped(out, colText(ss.?, 4));
        try out.appendSlice(",\"currency\":");
        try appendJsonEscaped(out, cur);
        try out.appendSlice(",\"amount_formatted\":");
        try appendJsonEscaped(out, amt_fmt);
        try out.appendSlice(",\"rail_detail\":");
        try appendJsonEscaped(out, colText(ss.?, 7));
        try out.appendSlice(",\"status\":");
        try appendJsonEscaped(out, st);
        const nums = try std.fmt.allocPrint(
            alloc,
            ",\"units_limit\":{d},\"units_used\":{d},\"monthly_credits_left\":{d},\"rollover_credits\":{d},\"dunning_stage\":",
            .{ colInt(ss.?, 9), colInt(ss.?, 10), colInt(ss.?, 11), colInt(ss.?, 12) },
        );
        defer alloc.free(nums);
        try out.appendSlice(nums);
        try appendJsonEscaped(out, colText(ss.?, 13));
        try out.appendSlice(",\"portal_token\":");
        try appendJsonEscaped(out, colText(ss.?, 14));
        try out.append('}');
    }
    try out.appendSlice("],");

    // Agency Projects
    try out.appendSlice("\"projects\":[");
    var pr: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT id, title, client_name, client_company, client_phone, currency, subtotal_minor, vat_minor, gross_invoice_minor, wht_rate_bps, wht_credit_note_minor, net_cash_expected_minor, cash_paid_minor, wht_cert_status, revisions_included, revisions_used, extra_revision_fee_minor, pending_addon_minor, vault_unlocked, payment_rail, portal_token FROM agency_projects ORDER BY created_at DESC;", -1, &pr, null);
    defer _ = c.sqlite3_finalize(pr.?);
    var first_pr = true;
    while (c.sqlite3_step(pr.?) == c.SQLITE_ROW) {
        if (!first_pr) try out.append(',');
        first_pr = false;

        const pid = colText(pr.?, 0);
        const cur = colText(pr.?, 5);
        const paid: i128 = colInt(pr.?, 12);
        for (cur_codes, 0..) |cc, idx| {
            if (std.ascii.eqlIgnoreCase(cur, cc)) totals[idx] += paid;
        }
        const net_exp: i128 = colInt(pr.?, 11) + colInt(pr.?, 17);
        const rem: i128 = if (net_exp > paid) net_exp - paid else 0;
        const unlocked = colInt(pr.?, 18) == 1;

        const gross_f = try formatMoneyAlloc(alloc, colInt(pr.?, 8), cur);
        defer alloc.free(gross_f);
        const wht_f = try formatMoneyAlloc(alloc, colInt(pr.?, 10), cur);
        defer alloc.free(wht_f);
        const net_f = try formatMoneyAlloc(alloc, net_exp, cur);
        defer alloc.free(net_f);
        const paid_f = try formatMoneyAlloc(alloc, paid, cur);
        defer alloc.free(paid_f);
        const rem_f = try formatMoneyAlloc(alloc, rem, cur);
        defer alloc.free(rem_f);
        const xrev_f = try formatMoneyAlloc(alloc, colInt(pr.?, 16), cur);
        defer alloc.free(xrev_f);

        try out.appendSlice("{\"id\":");
        try appendJsonEscaped(out, pid);
        try out.appendSlice(",\"title\":");
        try appendJsonEscaped(out, colText(pr.?, 1));
        try out.appendSlice(",\"client_name\":");
        try appendJsonEscaped(out, colText(pr.?, 2));
        try out.appendSlice(",\"client_company\":");
        try appendJsonEscaped(out, colText(pr.?, 3));
        try out.appendSlice(",\"client_phone\":");
        try appendJsonEscaped(out, colText(pr.?, 4));
        try out.appendSlice(",\"currency\":");
        try appendJsonEscaped(out, cur);
        try out.appendSlice(",\"gross_formatted\":");
        try appendJsonEscaped(out, gross_f);
        try out.appendSlice(",\"wht_formatted\":");
        try appendJsonEscaped(out, wht_f);
        try out.appendSlice(",\"net_cash_formatted\":");
        try appendJsonEscaped(out, net_f);
        try out.appendSlice(",\"cash_paid_formatted\":");
        try appendJsonEscaped(out, paid_f);
        try out.appendSlice(",\"remaining_formatted\":");
        try appendJsonEscaped(out, rem_f);
        try out.appendSlice(",\"extra_rev_formatted\":");
        try appendJsonEscaped(out, xrev_f);
        try out.appendSlice(",\"wht_cert_status\":");
        try appendJsonEscaped(out, colText(pr.?, 13));
        try out.appendSlice(",\"payment_rail\":");
        try appendJsonEscaped(out, colText(pr.?, 19));
        try out.appendSlice(",\"portal_token\":");
        try appendJsonEscaped(out, colText(pr.?, 20));

        const pnums = try std.fmt.allocPrint(
            alloc,
            ",\"wht_rate_bps\":{d},\"remaining_minor\":{d},\"revisions_included\":{d},\"revisions_used\":{d},\"vault_unlocked\":{s},\"deliverables\":[",
            .{ colInt(pr.?, 9), @as(i64, @intCast(rem)), colInt(pr.?, 14), colInt(pr.?, 15), if (unlocked) "true" else "false" },
        );
        defer alloc.free(pnums);
        try out.appendSlice(pnums);

        var ds: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "SELECT id, title, watermarked_preview, unlocked_secret_url FROM project_deliverables WHERE project_id = ?1;", -1, &ds, null);
        defer _ = c.sqlite3_finalize(ds.?);
        bindText(ds.?, 1, pid);
        var first_d = true;
        while (c.sqlite3_step(ds.?) == c.SQLITE_ROW) {
            if (!first_d) try out.append(',');
            first_d = false;
            try out.appendSlice("{\"id\":");
            try appendJsonEscaped(out, colText(ds.?, 0));
            try out.appendSlice(",\"title\":");
            try appendJsonEscaped(out, colText(ds.?, 1));
            try out.appendSlice(",\"preview\":");
            try appendJsonEscaped(out, colText(ds.?, 2));
            try out.appendSlice(",\"download_url\":");
            if (unlocked) {
                try appendJsonEscaped(out, colText(ds.?, 3));
            } else {
                try out.appendSlice("\"\"");
            }
            try out.append('}');
        }
        try out.appendSlice("]}");
    }
    try out.appendSlice("],");

    // Ad Attribution Leads
    try out.appendSlice("\"leads\":[");
    var ld: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT id, platform, campaign_name, creative_name, click_id, ad_spend_minor, customer_name, customer_phone, whatsapp_first_msg, currency, expected_amount_minor, verified_paid_minor, payment_rail, fake_screenshots_blocked, capi_status, capi_event_id FROM ad_leads ORDER BY created_at DESC;", -1, &ld, null);
    defer _ = c.sqlite3_finalize(ld.?);
    var first_l = true;
    while (c.sqlite3_step(ld.?) == c.SQLITE_ROW) {
        if (!first_l) try out.append(',');
        first_l = false;

        const cur = colText(ld.?, 9);
        const vpaid: i128 = colInt(ld.?, 11);
        for (cur_codes, 0..) |cc, idx| {
            if (std.ascii.eqlIgnoreCase(cur, cc)) totals[idx] += vpaid;
        }
        const exp_f = try formatMoneyAlloc(alloc, colInt(ld.?, 10), cur);
        defer alloc.free(exp_f);
        const spend_f = try formatMoneyAlloc(alloc, colInt(ld.?, 5), cur);
        defer alloc.free(spend_f);

        try out.appendSlice("{\"id\":");
        try appendJsonEscaped(out, colText(ld.?, 0));
        try out.appendSlice(",\"platform\":");
        try appendJsonEscaped(out, colText(ld.?, 1));
        try out.appendSlice(",\"campaign_name\":");
        try appendJsonEscaped(out, colText(ld.?, 2));
        try out.appendSlice(",\"creative_name\":");
        try appendJsonEscaped(out, colText(ld.?, 3));
        try out.appendSlice(",\"click_id\":");
        try appendJsonEscaped(out, colText(ld.?, 4));
        try out.appendSlice(",\"spend_formatted\":");
        try appendJsonEscaped(out, spend_f);
        try out.appendSlice(",\"customer_name\":");
        try appendJsonEscaped(out, colText(ld.?, 6));
        try out.appendSlice(",\"customer_phone\":");
        try appendJsonEscaped(out, colText(ld.?, 7));
        try out.appendSlice(",\"whatsapp_first_msg\":");
        try appendJsonEscaped(out, colText(ld.?, 8));
        try out.appendSlice(",\"currency\":");
        try appendJsonEscaped(out, cur);
        try out.appendSlice(",\"expected_formatted\":");
        try appendJsonEscaped(out, exp_f);
        try out.appendSlice(",\"payment_rail\":");
        try appendJsonEscaped(out, colText(ld.?, 12));
        try out.appendSlice(",\"capi_status\":");
        try appendJsonEscaped(out, colText(ld.?, 14));
        try out.appendSlice(",\"capi_event_id\":");
        try appendJsonEscaped(out, colText(ld.?, 15));
        const lnums = try std.fmt.allocPrint(alloc, ",\"spend_minor\":{d},\"verified_minor\":{d},\"fake_blocked\":{d}}}", .{ colInt(ld.?, 5), colInt(ld.?, 11), colInt(ld.?, 13) });
        defer alloc.free(lnums);
        try out.appendSlice(lnums);
    }
    try out.appendSlice("],");

    // Fiscal Invoices
    try out.appendSlice("\"invoices\":[");
    var fi: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT id, invoice_number, source_kind, buyer_name, buyer_tin, authority, currency, subtotal_minor, vat_minor, wht_minor, payable_cash_minor, fiscal_status, irn_or_cu, csid_hash, qr_payload, retry_count, error_detail FROM fiscal_invoices ORDER BY created_at DESC;", -1, &fi, null);
    defer _ = c.sqlite3_finalize(fi.?);
    var first_f = true;
    while (c.sqlite3_step(fi.?) == c.SQLITE_ROW) {
        if (!first_f) try out.append(',');
        first_f = false;
        const cur = colText(fi.?, 6);
        const sub_f = try formatMoneyAlloc(alloc, colInt(fi.?, 7), cur);
        defer alloc.free(sub_f);
        const vat_f = try formatMoneyAlloc(alloc, colInt(fi.?, 8), cur);
        defer alloc.free(vat_f);
        const wht_f = try formatMoneyAlloc(alloc, colInt(fi.?, 9), cur);
        defer alloc.free(wht_f);
        const pay_f = try formatMoneyAlloc(alloc, colInt(fi.?, 10), cur);
        defer alloc.free(pay_f);

        try out.appendSlice("{\"id\":");
        try appendJsonEscaped(out, colText(fi.?, 0));
        try out.appendSlice(",\"invoice_number\":");
        try appendJsonEscaped(out, colText(fi.?, 1));
        try out.appendSlice(",\"source_kind\":");
        try appendJsonEscaped(out, colText(fi.?, 2));
        try out.appendSlice(",\"buyer_name\":");
        try appendJsonEscaped(out, colText(fi.?, 3));
        try out.appendSlice(",\"buyer_tin\":");
        try appendJsonEscaped(out, colText(fi.?, 4));
        try out.appendSlice(",\"authority\":");
        try appendJsonEscaped(out, colText(fi.?, 5));
        try out.appendSlice(",\"subtotal_formatted\":");
        try appendJsonEscaped(out, sub_f);
        try out.appendSlice(",\"vat_formatted\":");
        try appendJsonEscaped(out, vat_f);
        try out.appendSlice(",\"wht_formatted\":");
        try appendJsonEscaped(out, wht_f);
        try out.appendSlice(",\"payable_formatted\":");
        try appendJsonEscaped(out, pay_f);
        try out.appendSlice(",\"fiscal_status\":");
        try appendJsonEscaped(out, colText(fi.?, 11));
        try out.appendSlice(",\"irn_or_cu\":");
        try appendJsonEscaped(out, colText(fi.?, 12));
        try out.appendSlice(",\"csid_hash\":");
        try appendJsonEscaped(out, colText(fi.?, 13));
        try out.appendSlice(",\"qr_payload\":");
        try appendJsonEscaped(out, colText(fi.?, 14));
        const rnum = try std.fmt.allocPrint(alloc, ",\"retry_count\":{d},\"error_detail\":", .{colInt(fi.?, 15)});
        defer alloc.free(rnum);
        try out.appendSlice(rnum);
        try appendJsonEscaped(out, colText(fi.?, 16));
        try out.append('}');
    }
    try out.appendSlice("],");

    // Outbox Events
    try out.appendSlice("\"events\":[");
    var ev: ?*c.sqlite3_stmt = null;
    _ = c.sqlite3_prepare_v2(db, "SELECT id, target, event_type, recipient_or_endpoint, status, credits_used, signature_header, payload_json, created_at FROM outbox_events ORDER BY rowid DESC LIMIT 30;", -1, &ev, null);
    defer _ = c.sqlite3_finalize(ev.?);
    var first_e = true;
    while (c.sqlite3_step(ev.?) == c.SQLITE_ROW) {
        if (!first_e) try out.append(',');
        first_e = false;
        try out.appendSlice("{\"id\":");
        try appendJsonEscaped(out, colText(ev.?, 0));
        try out.appendSlice(",\"target\":");
        try appendJsonEscaped(out, colText(ev.?, 1));
        try out.appendSlice(",\"event_type\":");
        try appendJsonEscaped(out, colText(ev.?, 2));
        try out.appendSlice(",\"destination\":");
        try appendJsonEscaped(out, colText(ev.?, 3));
        try out.appendSlice(",\"status\":");
        try appendJsonEscaped(out, colText(ev.?, 4));
        const cnum = try std.fmt.allocPrint(alloc, ",\"credits_used\":{d},\"signature_header\":", .{colInt(ev.?, 5)});
        defer alloc.free(cnum);
        try out.appendSlice(cnum);
        try appendJsonEscaped(out, colText(ev.?, 6));
        try out.appendSlice(",\"payload_json\":");
        try appendJsonEscaped(out, colText(ev.?, 7));
        try out.appendSlice(",\"created_at\":");
        try appendJsonEscaped(out, colText(ev.?, 8));
        try out.append('}');
    }
    try out.appendSlice("],");

    // Ledger summary per currency (exact minor units, never cross-currency float summed)
    try out.appendSlice("\"ledger\":[");
    var first_leg = true;
    for (cur_codes, 0..) |cc, idx| {
        if (totals[idx] <= 0) continue;
        if (!first_leg) try out.append(',');
        first_leg = false;
        const spec = getCurrencySpec(cc);
        const fmt_str = try formatMoneyAlloc(alloc, totals[idx], cc);
        defer alloc.free(fmt_str);
        const item = try std.fmt.allocPrint(
            alloc,
            "{{\"currency\":\"{s}\",\"decimals\":{d},\"amount_minor\":{d},\"formatted\":\"{s}\"}}",
            .{ cc, spec.decimals, @as(i64, @intCast(totals[idx])), fmt_str },
        );
        defer alloc.free(item);
        try out.appendSlice(item);
    }
    try out.appendSlice("]}");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 3) {
        try std.io.getStdOut().writer().writeAll("{\"ok\":false,\"error\":\"usage: ugwo-kernel <db_path> <cmd> [arg]\"}\n");
        return;
    }

    const db_path_z = try alloc.dupeZ(u8, args[1]);
    defer alloc.free(db_path_z);
    const cmd = args[2];
    const arg = if (args.len >= 4) args[3] else "";

    var db_opt: ?*c.sqlite3 = null;
    if (c.sqlite3_open(db_path_z.ptr, &db_opt) != c.SQLITE_OK) {
        try std.io.getStdOut().writer().writeAll("{\"ok\":false,\"error\":\"sqlite_open_failed\"}\n");
        return;
    }
    const db = db_opt.?;
    defer _ = c.sqlite3_close(db);
    _ = c.sqlite3_busy_timeout(db, 5000);

    try initSchemaAndSeed(alloc, db);

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    var notice_msg: []const u8 = "State synchronized.";
    var dynamic_notice: ?[]u8 = null;
    defer if (dynamic_notice) |dn| alloc.free(dn);

    if (std.mem.eql(u8, cmd, "sub_consume")) {
        var s: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "SELECT units_limit, units_used, monthly_credits_left, rollover_credits FROM subscriptions WHERE id = ?1;", -1, &s, null);
        defer _ = c.sqlite3_finalize(s.?);
        bindText(s.?, 1, arg);
        if (c.sqlite3_step(s.?) == c.SQLITE_ROW) {
            const u_lim: i128 = colInt(s.?, 0);
            const u_used: i128 = colInt(s.?, 1);
            const m_left: i128 = colInt(s.?, 2);
            const r_left: i128 = colInt(s.?, 3);
            const need: i128 = 250;
            const u_after = try std.math.add(i128, u_used, 3500);
            if (u_after > u_lim or need > (m_left + r_left)) {
                dynamic_notice = try alloc.dupe(u8, "HTTP 429 Polite Cap: quota or credits exhausted; zero surprise card charge.");
            } else {
                const from_m = if (m_left >= need) need else m_left;
                const from_r = need - from_m;
                var u: ?*c.sqlite3_stmt = null;
                _ = c.sqlite3_prepare_v2(db, "UPDATE subscriptions SET monthly_credits_left = ?1, rollover_credits = ?2, units_used = ?3 WHERE id = ?4;", -1, &u, null);
                defer _ = c.sqlite3_finalize(u.?);
                _ = c.sqlite3_bind_int64(u.?, 1, @intCast(m_left - from_m));
                _ = c.sqlite3_bind_int64(u.?, 2, @intCast(r_left - from_r));
                _ = c.sqlite3_bind_int64(u.?, 3, @intCast(u_after));
                bindText(u.?, 4, arg);
                _ = c.sqlite3_step(u.?);
                dynamic_notice = try std.fmt.allocPrint(alloc, "Zig i128 meter deducted 250 credits ({d} monthly included, {d} non-expiring rollover).", .{ @as(i64, @intCast(from_m)), @as(i64, @intCast(from_r)) });
            }
        }
    } else if (std.mem.eql(u8, cmd, "sub_topup")) {
        var u: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "UPDATE subscriptions SET rollover_credits = rollover_credits + 2500 WHERE id = ?1;", -1, &u, null);
        defer _ = c.sqlite3_finalize(u.?);
        bindText(u.?, 1, arg);
        _ = c.sqlite3_step(u.?);
        const payload = try std.fmt.allocPrint(alloc, "{{\"subscription_id\":\"{s}\",\"credits_added\":2500}}", .{arg});
        defer alloc.free(payload);
        const sig = try emitFlowMationHook(alloc, db, "credits.topup.settled", payload);
        alloc.free(sig);
        dynamic_notice = try alloc.dupe(u8, "Added +2,500 non-expiring rollover credits and emitted signed FlowMation hook.");
    } else if (std.mem.eql(u8, cmd, "sub_dunning")) {
        var s: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "SELECT customer_phone, status, currency, amount_minor FROM subscriptions WHERE id = ?1;", -1, &s, null);
        defer _ = c.sqlite3_finalize(s.?);
        bindText(s.?, 1, arg);
        if (c.sqlite3_step(s.?) == c.SQLITE_ROW) {
            const phone = try alloc.dupe(u8, colText(s.?, 0));
            defer alloc.free(phone);
            const active = std.mem.eql(u8, colText(s.?, 1), "active");
            const fmt_amt = try formatMoneyAlloc(alloc, colInt(s.?, 3), colText(s.?, 2));
            defer alloc.free(fmt_amt);
            if (active) {
                try emitOutboxEvent(alloc, db, "senviok_whatsapp", "subscription.whatsapp_dunning", phone, "suppressed_stop_on_paid", 0, "stop_on_paid_guard", "{\"guard\":\"Subscriber active; suppressed at 0 Senviok credits.\"}");
                dynamic_notice = try alloc.dupe(u8, "Stop-on-Paid Guard: subscriber already active; suppressed WhatsApp send at 0 Senviok credits.");
            } else {
                const pjson = try std.fmt.allocPrint(alloc, "{{\"amount_due\":\"{s}\",\"channel\":\"whatsapp\"}}", .{fmt_amt});
                defer alloc.free(pjson);
                try emitOutboxEvent(alloc, db, "senviok_whatsapp", "subscription.whatsapp_dunning", phone, "delivered", 4, "svk_live_whatsapp", pjson);
                dynamic_notice = try std.fmt.allocPrint(alloc, "Dispatched Senviok 1-tap WhatsApp renewal link for {s} (4 credits).", .{fmt_amt});
            }
        }
    } else if (std.mem.eql(u8, cmd, "sub_settle")) {
        var s: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "SELECT customer_company, buyer_tin, currency, amount_minor, customer_phone FROM subscriptions WHERE id = ?1;", -1, &s, null);
        defer _ = c.sqlite3_finalize(s.?);
        bindText(s.?, 1, arg);
        if (c.sqlite3_step(s.?) == c.SQLITE_ROW) {
            const comp = try alloc.dupe(u8, colText(s.?, 0));
            defer alloc.free(comp);
            const tin = try alloc.dupe(u8, colText(s.?, 1));
            defer alloc.free(tin);
            const cur = try alloc.dupe(u8, colText(s.?, 2));
            defer alloc.free(cur);
            const amt: i128 = colInt(s.?, 3);
            const phone = try alloc.dupe(u8, colText(s.?, 4));
            defer alloc.free(phone);

            var u: ?*c.sqlite3_stmt = null;
            _ = c.sqlite3_prepare_v2(db, "UPDATE subscriptions SET status = 'active', dunning_stage = 'recovered', units_used = 0, monthly_credits_left = 2500 WHERE id = ?1;", -1, &u, null);
            defer _ = c.sqlite3_finalize(u.?);
            bindText(u.?, 1, arg);
            _ = c.sqlite3_step(u.?);

            const vat_bps: i128 = if (std.ascii.eqlIgnoreCase(cur, "KES")) 1600 else if (std.ascii.eqlIgnoreCase(cur, "NGN")) 750 else 0;
            const base: i128 = if (vat_bps > 0) @divTrunc(amt * 10000, 10000 + vat_bps) else amt;
            const fisc = try issueFiscalInvoice(alloc, db, "subscription", arg, comp, tin, cur, base, amt - base, 0, amt);
            defer alloc.free(fisc.invoice_number);
            defer alloc.free(fisc.fiscal_status);
            defer alloc.free(fisc.irn);

            try emitOutboxEvent(alloc, db, "senviok_whatsapp", "dunning.auto_cancel_on_settlement", phone, "suppressed_stop_on_paid", 0, "stop_on_paid_guard", "{\"guard\":\"Renewal settled; pending dunning cancelled at 0 credits.\"}");
            const hjson = try std.fmt.allocPrint(alloc, "{{\"subscription_id\":\"{s}\",\"amount_minor\":{d},\"fiscal\":\"{s}\"}}", .{ arg, @as(i64, @intCast(amt)), fisc.invoice_number });
            defer alloc.free(hjson);
            const sig = try emitFlowMationHook(alloc, db, "subscription.renewed", hjson);
            alloc.free(sig);

            const fmt_a = try formatMoneyAlloc(alloc, amt, cur);
            defer alloc.free(fmt_a);
            dynamic_notice = try std.fmt.allocPrint(alloc, "Settled {s}: Fiscal {s} ({s}) and signed FlowMation hook.", .{ fmt_a, fisc.invoice_number, fisc.fiscal_status });
        }
    } else if (std.mem.eql(u8, cmd, "sub_create")) {
        // arg format: company|contact|phone|country|currency|plan_id|tin
        var it = std.mem.splitScalar(u8, arg, '|');
        const company = it.next() orelse "New Startup Ltd";
        const contact = it.next() orelse "Adaeze Obi";
        const raw_phone = it.next() orelse "08031234567";
        const country = it.next() orelse "NG";
        const cur = it.next() orelse "NGN";
        const plan_id = it.next() orelse "plan_growth";
        const tin = it.next() orelse "TIN-90128374-0001";

        const e164 = try normalizeE164(alloc, raw_phone, country);
        defer alloc.free(e164);

        const amt: i128 = if (std.ascii.eqlIgnoreCase(cur, "XOF"))
            19500
        else if (std.ascii.eqlIgnoreCase(cur, "KES"))
            420000
        else if (std.ascii.eqlIgnoreCase(cur, "GHS"))
            48000
        else if (std.ascii.eqlIgnoreCase(cur, "ZAR"))
            59000
        else
            4000000;

        const sid = try randomHexId(alloc, "sub");
        defer alloc.free(sid);
        const tok = try randomHexId(alloc, "cap_sub");
        defer alloc.free(tok);
        const ts = try nowIsoAlloc(alloc);
        defer alloc.free(ts);
        const rail_det = try std.fmt.allocPrint(alloc, "Dedicated Local Transfer / MoMo Rail: {s}", .{e164});
        defer alloc.free(rail_det);

        var ins: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "INSERT INTO subscriptions VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'local_rail', ?9, 'active', 250000, 0, 2500, 0, 'none', ?10, ?11);", -1, &ins, null);
        defer _ = c.sqlite3_finalize(ins.?);
        bindText(ins.?, 1, sid);
        bindText(ins.?, 2, plan_id);
        bindText(ins.?, 3, contact);
        bindText(ins.?, 4, company);
        bindText(ins.?, 5, e164);
        bindText(ins.?, 6, tin);
        bindText(ins.?, 7, cur);
        _ = c.sqlite3_bind_int64(ins.?, 8, @intCast(amt));
        bindText(ins.?, 9, rail_det);
        bindText(ins.?, 10, tok);
        bindText(ins.?, 11, ts);
        _ = c.sqlite3_step(ins.?);

        const fisc = try issueFiscalInvoice(alloc, db, "subscription", sid, company, tin, cur, amt, 0, 0, amt);
        defer alloc.free(fisc.invoice_number);
        defer alloc.free(fisc.fiscal_status);
        defer alloc.free(fisc.irn);
        dynamic_notice = try std.fmt.allocPrint(alloc, "Provisioned {s} ({s}): Fiscal {s} ({s}).", .{ company, e164, fisc.invoice_number, fisc.fiscal_status });
    } else if (std.mem.eql(u8, cmd, "proj_revision")) {
        var s: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "SELECT revisions_included, revisions_used, extra_revision_fee_minor, currency, client_phone, client_company FROM agency_projects WHERE id = ?1;", -1, &s, null);
        defer _ = c.sqlite3_finalize(s.?);
        bindText(s.?, 1, arg);
        if (c.sqlite3_step(s.?) == c.SQLITE_ROW) {
            const inc = colInt(s.?, 0);
            const used = colInt(s.?, 1);
            const fee: i128 = colInt(s.?, 2);
            const cur = try alloc.dupe(u8, colText(s.?, 3));
            defer alloc.free(cur);
            const phone = try alloc.dupe(u8, colText(s.?, 4));
            defer alloc.free(phone);
            const comp = try alloc.dupe(u8, colText(s.?, 5));
            defer alloc.free(comp);

            if (used < inc) {
                var u: ?*c.sqlite3_stmt = null;
                _ = c.sqlite3_prepare_v2(db, "UPDATE agency_projects SET revisions_used = revisions_used + 1 WHERE id = ?1;", -1, &u, null);
                defer _ = c.sqlite3_finalize(u.?);
                bindText(u.?, 1, arg);
                _ = c.sqlite3_step(u.?);
                dynamic_notice = try std.fmt.allocPrint(alloc, "Logged client revision within scope ({d} of {d} used).", .{ used + 1, inc });
            } else {
                var u: ?*c.sqlite3_stmt = null;
                _ = c.sqlite3_prepare_v2(db, "UPDATE agency_projects SET revisions_used = revisions_used + 1, pending_addon_minor = pending_addon_minor + ?1, vault_unlocked = 0 WHERE id = ?2;", -1, &u, null);
                defer _ = c.sqlite3_finalize(u.?);
                _ = c.sqlite3_bind_int64(u.?, 1, @intCast(fee));
                bindText(u.?, 2, arg);
                _ = c.sqlite3_step(u.?);

                const fee_fmt = try formatMoneyAlloc(alloc, fee, cur);
                defer alloc.free(fee_fmt);
                const msg_json = try std.fmt.allocPrint(alloc, "{{\"client\":\"{s}\",\"change_order_fee\":\"{s}\"}}", .{ comp, fee_fmt });
                defer alloc.free(msg_json);
                try emitOutboxEvent(alloc, db, "senviok_whatsapp", "agency.scope_guard_change_order", phone, "delivered", 4, "svk_live_scope_guard", msg_json);
                const sig = try emitFlowMationHook(alloc, db, "agency.revision.limit_exceeded", msg_json);
                alloc.free(sig);
                dynamic_notice = try std.fmt.allocPrint(alloc, "Scope-Guard activated: all {d} revisions exhausted; added {s} change-order fee and locked vault.", .{ inc, fee_fmt });
            }
        }
    } else if (std.mem.eql(u8, cmd, "proj_settle")) {
        var s: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "SELECT client_company, buyer_tin, currency, subtotal_minor, vat_minor, wht_credit_note_minor, net_cash_expected_minor, pending_addon_minor, client_phone FROM agency_projects WHERE id = ?1;", -1, &s, null);
        defer _ = c.sqlite3_finalize(s.?);
        bindText(s.?, 1, arg);
        if (c.sqlite3_step(s.?) == c.SQLITE_ROW) {
            const comp = try alloc.dupe(u8, colText(s.?, 0));
            defer alloc.free(comp);
            const tin = try alloc.dupe(u8, colText(s.?, 1));
            defer alloc.free(tin);
            const cur = try alloc.dupe(u8, colText(s.?, 2));
            defer alloc.free(cur);
            const sub_m: i128 = colInt(s.?, 3) + colInt(s.?, 7);
            const vat_m: i128 = colInt(s.?, 4);
            const wht_m: i128 = colInt(s.?, 5);
            const total_cash: i128 = colInt(s.?, 6) + colInt(s.?, 7);
            const phone = try alloc.dupe(u8, colText(s.?, 8));
            defer alloc.free(phone);

            var u: ?*c.sqlite3_stmt = null;
            _ = c.sqlite3_prepare_v2(db, "UPDATE agency_projects SET cash_paid_minor = ?1, vault_unlocked = 1 WHERE id = ?2;", -1, &u, null);
            defer _ = c.sqlite3_finalize(u.?);
            _ = c.sqlite3_bind_int64(u.?, 1, @intCast(total_cash));
            bindText(u.?, 2, arg);
            _ = c.sqlite3_step(u.?);

            const fisc = try issueFiscalInvoice(alloc, db, "agency_milestone", arg, comp, tin, cur, sub_m, vat_m, wht_m, total_cash);
            defer alloc.free(fisc.invoice_number);
            defer alloc.free(fisc.fiscal_status);
            defer alloc.free(fisc.irn);

            const cash_fmt = try formatMoneyAlloc(alloc, total_cash, cur);
            defer alloc.free(cash_fmt);
            const hjson = try std.fmt.allocPrint(alloc, "{{\"project_id\":\"{s}\",\"vault_unlocked\":true,\"fiscal\":\"{s}\"}}", .{ arg, fisc.invoice_number });
            defer alloc.free(hjson);
            try emitOutboxEvent(alloc, db, "senviok_whatsapp", "agency.vault_unlocked", phone, "delivered", 4, "svk_live_unlock", hjson);
            const sig = try emitFlowMationHook(alloc, db, "agency.milestone.unlocked", hjson);
            alloc.free(sig);
            dynamic_notice = try std.fmt.allocPrint(alloc, "Settled {s}: Asset Vault unlocked, Fiscal {s} ({s}).", .{ cash_fmt, fisc.invoice_number, fisc.fiscal_status });
        }
    } else if (std.mem.eql(u8, cmd, "proj_create")) {
        // title|company|contact|phone|currency|subtotal_major|wht_bps|rev_cap|deliverable
        var it = std.mem.splitScalar(u8, arg, '|');
        const title = it.next() orelse "Brand & Web Platform Retainer";
        const company = it.next() orelse "Zuri Retail Group";
        const contact = it.next() orelse "Adebayo Ogunlesi";
        const raw_phone = it.next() orelse "08062219044";
        const cur = it.next() orelse "NGN";
        const sub_maj_str = it.next() orelse "1200000";
        const wht_str = it.next() orelse "500";
        const rev_str = it.next() orelse "2";
        const deliv = it.next() orelse "Figma Master System + Production Storefront Repo";

        const spec = getCurrencySpec(cur);
        const factor: i128 = if (spec.decimals == 0) 1 else 100;
        const sub_maj = std.fmt.parseInt(i128, sub_maj_str, 10) catch 1200000;
        const sub_minor = try std.math.mul(i128, sub_maj, factor);
        const wht_bps = std.fmt.parseInt(i128, wht_str, 10) catch 500;
        const vat_bps: i128 = if (std.ascii.eqlIgnoreCase(cur, "KES")) 1600 else if (std.ascii.eqlIgnoreCase(cur, "NGN")) 750 else 0;
        const rev_cap = std.fmt.parseInt(i64, rev_str, 10) catch 2;

        const split = try computeTaxAndWht(sub_minor, vat_bps, wht_bps);
        const e164 = try normalizeE164(alloc, raw_phone, if (std.ascii.eqlIgnoreCase(cur, "KES")) "KE" else "NG");
        defer alloc.free(e164);

        const pid = try randomHexId(alloc, "proj");
        defer alloc.free(pid);
        const tok = try randomHexId(alloc, "portal");
        defer alloc.free(tok);
        const did = try randomHexId(alloc, "del");
        defer alloc.free(did);
        const ts = try nowIsoAlloc(alloc);
        defer alloc.free(ts);
        const extra_fee = @divTrunc(sub_minor, 10);

        var ins: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "INSERT INTO agency_projects VALUES (?1, ?2, ?3, ?4, ?5, 'TIN-66201944-0001', ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, 0, ?14, ?15, 0, ?16, 0, 0, 'Paystack / MoMo Milestone Rail', ?17, ?18);", -1, &ins, null);
        defer _ = c.sqlite3_finalize(ins.?);
        bindText(ins.?, 1, pid);
        bindText(ins.?, 2, title);
        bindText(ins.?, 3, contact);
        bindText(ins.?, 4, company);
        bindText(ins.?, 5, e164);
        bindText(ins.?, 6, cur);
        _ = c.sqlite3_bind_int64(ins.?, 7, @intCast(split.subtotal_minor));
        _ = c.sqlite3_bind_int64(ins.?, 8, @intCast(vat_bps));
        _ = c.sqlite3_bind_int64(ins.?, 9, @intCast(wht_bps));
        _ = c.sqlite3_bind_int64(ins.?, 10, @intCast(split.vat_minor));
        _ = c.sqlite3_bind_int64(ins.?, 11, @intCast(split.gross_minor));
        _ = c.sqlite3_bind_int64(ins.?, 12, @intCast(split.wht_minor));
        _ = c.sqlite3_bind_int64(ins.?, 13, @intCast(split.net_cash_minor));
        bindText(ins.?, 14, if (wht_bps > 0) "pending_cert" else "not_applicable");
        _ = c.sqlite3_bind_int64(ins.?, 15, rev_cap);
        _ = c.sqlite3_bind_int64(ins.?, 16, @intCast(extra_fee));
        bindText(ins.?, 17, tok);
        bindText(ins.?, 18, ts);
        _ = c.sqlite3_step(ins.?);

        var dins: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "INSERT INTO project_deliverables VALUES (?1, ?2, ?3, 'WATERMARKED PREVIEW: Locked until net cash collectible settles.', 'https://cdn.ugwo.live/vault/client-release-signed.zip');", -1, &dins, null);
        defer _ = c.sqlite3_finalize(dins.?);
        bindText(dins.?, 1, did);
        bindText(dins.?, 2, pid);
        bindText(dins.?, 3, deliv);
        _ = c.sqlite3_step(dins.?);

        dynamic_notice = try std.fmt.allocPrint(alloc, "Created protected milestone for {s} with WHT basis-point split.", .{company});
    } else if (std.mem.eql(u8, cmd, "lead_fake")) {
        var u: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "UPDATE ad_leads SET fake_screenshots_blocked = fake_screenshots_blocked + 1 WHERE id = ?1;", -1, &u, null);
        defer _ = c.sqlite3_finalize(u.?);
        bindText(u.?, 1, arg);
        _ = c.sqlite3_step(u.?);
        const hjson = try std.fmt.allocPrint(alloc, "{{\"lead_id\":\"{s}\",\"reason\":\"Unverified transfer screenshot blocked\"}}", .{arg});
        defer alloc.free(hjson);
        const sig = try emitFlowMationHook(alloc, db, "attribution.fake_receipt.blocked", hjson);
        alloc.free(sig);
        dynamic_notice = try alloc.dupe(u8, "Blocked unverified transfer screenshot and suppressed Meta CAPI Purchase.");
    } else if (std.mem.eql(u8, cmd, "lead_verify")) {
        var s: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "SELECT customer_name, customer_phone, currency, expected_amount_minor, click_id, creative_name FROM ad_leads WHERE id = ?1;", -1, &s, null);
        defer _ = c.sqlite3_finalize(s.?);
        bindText(s.?, 1, arg);
        if (c.sqlite3_step(s.?) == c.SQLITE_ROW) {
            const cname = try alloc.dupe(u8, colText(s.?, 0));
            defer alloc.free(cname);
            const phone = try alloc.dupe(u8, colText(s.?, 1));
            defer alloc.free(phone);
            const cur = try alloc.dupe(u8, colText(s.?, 2));
            defer alloc.free(cur);
            const amt: i128 = colInt(s.?, 3);
            const clid = try alloc.dupe(u8, colText(s.?, 4));
            defer alloc.free(clid);
            const crname = try alloc.dupe(u8, colText(s.?, 5));
            defer alloc.free(crname);

            const capi_id = try randomHexId(alloc, "evt_capi");
            defer alloc.free(capi_id);

            var u: ?*c.sqlite3_stmt = null;
            _ = c.sqlite3_prepare_v2(db, "UPDATE ad_leads SET verified_paid_minor = expected_amount_minor, capi_status = 'capi_purchase_fired', capi_event_id = ?1 WHERE id = ?2;", -1, &u, null);
            defer _ = c.sqlite3_finalize(u.?);
            bindText(u.?, 1, capi_id);
            bindText(u.?, 2, arg);
            _ = c.sqlite3_step(u.?);

            const cjson = try std.fmt.allocPrint(alloc, "{{\"event_name\":\"Purchase\",\"event_id\":\"{s}\",\"ctwa_clid\":\"{s}\",\"creative\":\"{s}\",\"amount_minor\":{d}}}", .{ capi_id, clid, crname, @as(i64, @intCast(amt)) });
            defer alloc.free(cjson);
            try emitOutboxEvent(alloc, db, "meta_capi", "Purchase (Server-Side CAPI)", "META-PX-884920193", "delivered", 0, "sha256-pii-hashed", cjson);
            const sig = try emitFlowMationHook(alloc, db, "attribution.purchase.verified", cjson);
            alloc.free(sig);

            const fisc = try issueFiscalInvoice(alloc, db, "ad_commerce", arg, cname, "TIN-B2C-RETAIL", cur, amt, 0, 0, amt);
            defer alloc.free(fisc.invoice_number);
            defer alloc.free(fisc.fiscal_status);
            defer alloc.free(fisc.irn);
            try emitOutboxEvent(alloc, db, "senviok_whatsapp", "commerce.verified_receipt", phone, "delivered", 4, "svk_live_receipt", cjson);

            dynamic_notice = try std.fmt.allocPrint(alloc, "Verified settlement: fired Meta CAPI ({s}) and issued {s}.", .{ capi_id, fisc.invoice_number });
        }
    } else if (std.mem.eql(u8, cmd, "lead_create")) {
        // platform|campaign|creative|buyer|phone|currency|amount_major|msg
        var it = std.mem.splitScalar(u8, arg, '|');
        const platform = it.next() orelse "meta_ctwa";
        const campaign = it.next() orelse "Lagos_SME_Solar_Inverter_Q4";
        const creative = it.next() orelse "Reel_04_NoGenNoise_PidginHook";
        const buyer = it.next() orelse "Ngozi Eze";
        const raw_phone = it.next() orelse "08037719200";
        const cur = it.next() orelse "NGN";
        const amt_str = it.next() orelse "650000";
        const msg = it.next() orelse "Saw your IG Reel; send transfer account for the 2.5kVA office kit.";

        const spec = getCurrencySpec(cur);
        const factor: i128 = if (spec.decimals == 0) 1 else 100;
        const amt_maj = std.fmt.parseInt(i128, amt_str, 10) catch 650000;
        const amt_min = try std.math.mul(i128, amt_maj, factor);
        const spend_min = try std.math.mul(i128, 25000, factor);
        const e164 = try normalizeE164(alloc, raw_phone, if (std.ascii.eqlIgnoreCase(cur, "KES")) "KE" else "NG");
        defer alloc.free(e164);

        const lid = try randomHexId(alloc, "lead");
        defer alloc.free(lid);
        const clid = try randomHexId(alloc, if (std.mem.eql(u8, platform, "meta_ctwa")) "ctwa_clid" else "ttclid");
        defer alloc.free(clid);
        const ts = try nowIsoAlloc(alloc);
        defer alloc.free(ts);

        var ins: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "INSERT INTO ad_leads VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 0, 'Instant Bank Transfer / MoMo', 0, 'awaiting_settlement', '', ?12);", -1, &ins, null);
        defer _ = c.sqlite3_finalize(ins.?);
        bindText(ins.?, 1, lid);
        bindText(ins.?, 2, platform);
        bindText(ins.?, 3, campaign);
        bindText(ins.?, 4, creative);
        bindText(ins.?, 5, clid);
        _ = c.sqlite3_bind_int64(ins.?, 6, @intCast(spend_min));
        bindText(ins.?, 7, buyer);
        bindText(ins.?, 8, e164);
        bindText(ins.?, 9, msg);
        bindText(ins.?, 10, cur);
        _ = c.sqlite3_bind_int64(ins.?, 11, @intCast(amt_min));
        bindText(ins.?, 12, ts);
        _ = c.sqlite3_step(ins.?);
        dynamic_notice = try std.fmt.allocPrint(alloc, "Captured Click-to-WhatsApp lead ({s}).", .{clid});
    } else if (std.mem.eql(u8, cmd, "fiscal_toggle_outage")) {
        try execSql(db, "UPDATE workspace_settings SET gov_portal_outage_sim = CASE WHEN gov_portal_outage_sim = 1 THEN 0 ELSE 1 END;");
        dynamic_notice = try alloc.dupe(u8, "Toggled FIRS / KRA 504 outage circuit-breaker state.");
    } else if (std.mem.eql(u8, cmd, "fiscal_flush")) {
        try execSql(db, "UPDATE workspace_settings SET gov_portal_outage_sim = 0;");
        var ws: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "SELECT seller_tin FROM workspace_settings LIMIT 1;", -1, &ws, null);
        defer _ = c.sqlite3_finalize(ws.?);
        _ = c.sqlite3_step(ws.?);
        const seller_tin = try alloc.dupe(u8, colText(ws.?, 0));
        defer alloc.free(seller_tin);

        var q: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "SELECT id, invoice_number, buyer_tin, authority, currency, subtotal_minor, vat_minor FROM fiscal_invoices WHERE fiscal_status = 'queued_gov_outage';", -1, &q, null);
        defer _ = c.sqlite3_finalize(q.?);

        var flushed: usize = 0;
        while (c.sqlite3_step(q.?) == c.SQLITE_ROW) {
            const fid = try alloc.dupe(u8, colText(q.?, 0));
            defer alloc.free(fid);
            const inum = try alloc.dupe(u8, colText(q.?, 1));
            defer alloc.free(inum);
            const btin = try alloc.dupe(u8, colText(q.?, 2));
            defer alloc.free(btin);
            const auth = try alloc.dupe(u8, colText(q.?, 3));
            defer alloc.free(auth);
            const cur = try alloc.dupe(u8, colText(q.?, 4));
            defer alloc.free(cur);
            const gross: i128 = colInt(q.?, 5) + colInt(q.?, 6);

            const stamp = try computeFiscalStamp(alloc, auth, seller_tin, btin, inum, gross, cur);
            defer alloc.free(stamp.irn);
            defer alloc.free(stamp.csid);
            defer alloc.free(stamp.qr);

            var u: ?*c.sqlite3_stmt = null;
            _ = c.sqlite3_prepare_v2(db, "UPDATE fiscal_invoices SET fiscal_status = 'stamped', irn_or_cu = ?1, csid_hash = ?2, qr_payload = ?3, error_detail = '' WHERE id = ?4;", -1, &u, null);
            defer _ = c.sqlite3_finalize(u.?);
            bindText(u.?, 1, stamp.irn);
            bindText(u.?, 2, stamp.csid);
            bindText(u.?, 3, stamp.qr);
            bindText(u.?, 4, fid);
            _ = c.sqlite3_step(u.?);

            const hjson = try std.fmt.allocPrint(alloc, "{{\"invoice_number\":\"{s}\",\"irn\":\"{s}\",\"csid\":\"{s}\"}}", .{ inum, stamp.irn, stamp.csid });
            defer alloc.free(hjson);
            const sig = try emitFlowMationHook(alloc, db, "fiscal.invoice.stamped", hjson);
            alloc.free(sig);
            flushed += 1;
        }
        dynamic_notice = try std.fmt.allocPrint(alloc, "Flushed and cryptographically stamped {d} queued FIRS / eTIMS invoice(s).", .{flushed});
    }

    if (dynamic_notice) |dn| notice_msg = dn;

    try out.appendSlice("{\"ok\":true,\"notice\":");
    try appendJsonEscaped(&out, notice_msg);
    try out.appendSlice(",\"snapshot\":");
    try dumpFullStateJson(alloc, db, &out);
    try out.appendSlice("}\n");

    try std.io.getStdOut().writer().writeAll(out.items);
}
