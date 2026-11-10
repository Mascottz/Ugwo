import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http.{Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/otp/actor
import gleam/result
import gleam/string
import mist.{type ResponseData}

@external(erlang, "ugwo_ffi", "run_zig_kernel")
fn ffi_run_zig_kernel(
  bin_path: String,
  db_path: String,
  cmd: String,
  arg: String,
) -> Result(String, String)

@external(erlang, "ugwo_ffi", "read_static_file")
fn ffi_read_static_file(path: String) -> Result(BitArray, Nil)

@external(erlang, "ugwo_ffi", "get_env_or")
fn ffi_get_env_or(key: String, default: String) -> String

pub type ActorState {
  ActorState(
    bin_path: String,
    db_path: String,
    ops_count: Int,
    last_op: String,
  )
}

pub type ActorMsg {
  ExecuteOp(cmd: String, arg: String, reply_to: Subject(Result(String, String)))
}

fn handle_actor_msg(
  state: ActorState,
  msg: ActorMsg,
) -> actor.Next(ActorState, ActorMsg) {
  case msg {
    ExecuteOp(cmd, arg, reply_to) -> {
      let next_count = state.ops_count + 1
      let raw_res =
        ffi_run_zig_kernel(state.bin_path, state.db_path, cmd, arg)
      let enriched = case raw_res {
        Ok(json_str) -> {
          let trimmed = string.trim(json_str)
          let meta =
            ",\"runtime\":{\"gateway\":\"Gleam 1.19 on Erlang/OTP 27\",\"kernel\":\"Zig 0.13 ReleaseSafe i128 + SQLite WAL\",\"ui\":\"Elm 0.19.1 Pure MVU\",\"supervised_ops\":"
            <> int.to_string(next_count)
            <> ",\"last_op\":\""
            <> cmd
            <> "\"}}"
          case string.ends_with(trimmed, "}") {
            True -> Ok(string.drop_end(trimmed, 1) <> meta)
            False -> Ok(trimmed)
          }
        }
        Error(err) -> Error(err)
      }
      process.send(reply_to, enriched)
      actor.continue(
        ActorState(..state, ops_count: next_count, last_op: cmd),
      )
    }
  }
}

fn json_response(status: Int, body_str: String) -> Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body_str)))
}

fn serve_static(path: String, content_type: String) -> Response(ResponseData) {
  case ffi_read_static_file(path) {
    Ok(bits) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_header(
        "cache-control",
        "no-store, no-cache, must-revalidate, max-age=0",
      )
      |> response.set_header("pragma", "no-cache")
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(bits)))
    Error(_) ->
      json_response(404, "{\"ok\":false,\"error\":\"asset_not_found\"}")
  }
}

fn build_flowmation_pack_json() -> String {
  json.object([
    #("packId", json.string("ugwo_revenue_fiscal_pack_v1")),
    #(
      "name",
      json.string("Ụgwọ → FlowMation Supervised Fulfillment & Ops Pack"),
    ),
    #("installStatus", json.string("draft")),
    #("workspaceSlugHint", json.string("mastech-ops")),
    #(
      "webhookVerification",
      json.object([
        #("mode", json.string("generic_hmac_sha256")),
        #("header", json.string("X-Ugwo-Signature")),
        #("replayWindowSeconds", json.int(300)),
      ]),
    ),
    #(
      "workflows",
      json.preprocessed_array([
        json.object([
          #("name", json.string("ugwo-settlement-to-delivery")),
          #(
            "trigger",
            json.object([
              #("type", json.string("webhook")),
              #("path", json.string("/hooks/mastech-rev/ugwo")),
              #("verifySignature", json.bool(True)),
            ]),
          ),
          #(
            "steps",
            json.preprocessed_array([
              json.object([
                #("id", json.string("only_verified_settlement")),
                #("type", json.string("condition")),
                #(
                  "rule",
                  json.string(
                    "{{trigger.event}} in ['agency.milestone.unlocked', 'subscription.renewed', 'attribution.purchase.verified']",
                  ),
                ),
              ]),
              json.object([
                #("id", json.string("send_senviok_receipt")),
                #("type", json.string("connector")),
                #("provider", json.string("senviok")),
                #("action", json.string("send_whatsapp")),
                #(
                  "config",
                  json.object([
                    #(
                      "to",
                      json.string(
                        "{{trigger.data.customer_phone | default:+2348030000000 | e164:NG}}",
                      ),
                    ),
                    #(
                      "amount",
                      json.string(
                        "{{trigger.data.amount_minor | format_money:NGN}}",
                      ),
                    ),
                  ]),
                ),
              ]),
            ]),
          ),
        ]),
      ]),
    ),
  ])
  |> json.to_string
}

fn route_request(
  req: Request(BitArray),
  ledger_actor: Subject(ActorMsg),
  static_dir: String,
) -> Response(ResponseData) {
  let body_str =
    bit_array.to_string(req.body)
    |> result.unwrap("")
    |> string.trim

  let run_op = fn(cmd: String, arg: String) -> Response(ResponseData) {
    let reply = process.call(ledger_actor, 9000, ExecuteOp(cmd, arg, _))
    case reply {
      Ok(payload) -> json_response(200, payload)
      Error(reason) ->
        json_response(
          500,
          "{\"ok\":false,\"error\":\"" <> reason <> "\"}",
        )
    }
  }

  case req.method, request.path_segments(req) {
    Get, [] ->
      serve_static(static_dir <> "/index.html", "text/html; charset=utf-8")
    Get, ["assets", "styles.css"] ->
      serve_static(static_dir <> "/styles.css", "text/css; charset=utf-8")
    Get, ["assets", "ugwo.js"] ->
      serve_static(
        static_dir <> "/ugwo.js",
        "application/javascript; charset=utf-8",
      )
    Get, ["healthz"] ->
      json_response(200, "{\"ok\":true,\"service\":\"ugwo\",\"status\":\"healthy\"}")
    Get, ["api", "state"] -> run_op("state", "")
    Get, ["api", "ecosystem", "flowmation-pack.json"] ->
      json_response(200, build_flowmation_pack_json())

    Post, ["api", "subscriptions", "consume"] -> run_op("sub_consume", body_str)
    Post, ["api", "subscriptions", "topup"] -> run_op("sub_topup", body_str)
    Post, ["api", "subscriptions", "dunning"] -> run_op("sub_dunning", body_str)
    Post, ["api", "subscriptions", "settle"] -> run_op("sub_settle", body_str)
    Post, ["api", "subscriptions", "create"] -> run_op("sub_create", body_str)

    Post, ["api", "projects", "revision"] -> run_op("proj_revision", body_str)
    Post, ["api", "projects", "settle"] -> run_op("proj_settle", body_str)
    Post, ["api", "projects", "create"] -> run_op("proj_create", body_str)

    Post, ["api", "attribution", "fake"] -> run_op("lead_fake", body_str)
    Post, ["api", "attribution", "verify"] -> run_op("lead_verify", body_str)
    Post, ["api", "attribution", "create"] -> run_op("lead_create", body_str)

    Post, ["api", "fiscal", "toggle-outage"] ->
      run_op("fiscal_toggle_outage", "")
    Post, ["api", "fiscal", "flush"] -> run_op("fiscal_flush", "")

    _, _ -> json_response(404, "{\"ok\":false,\"error\":\"route_not_found\"}")
  }
}

pub fn main() {
  let bin_path = ffi_get_env_or("UGWO_KERNEL_BIN", "priv/bin/ugwo-kernel")
  let db_path = ffi_get_env_or("UGWO_DB_PATH", "priv/data/ugwo.db")
  let static_dir = ffi_get_env_or("UGWO_STATIC_DIR", "priv/static")
  let port_num =
    ffi_get_env_or("PORT", "3000")
    |> int.parse
    |> result.unwrap(3000)

  let initial =
    ActorState(
      bin_path: bin_path,
      db_path: db_path,
      ops_count: 0,
      last_op: "boot",
    )

  let assert Ok(started) =
    actor.new(initial)
    |> actor.on_message(handle_actor_msg)
    |> actor.start
  let ledger_actor = started.data

  let _ = process.call(ledger_actor, 9000, ExecuteOp("state", "", _))

  let bad_body_resp =
    json_response(413, "{\"ok\":false,\"error\":\"payload_too_large\"}")

  let assert Ok(_) =
    fn(req: Request(BitArray)) {
      route_request(req, ledger_actor, static_dir)
    }
    |> mist.new
    |> mist.read_request_body(
      bytes_limit: 1_048_576,
      failure_response: bad_body_resp,
    )
    |> mist.bind("0.0.0.0")
    |> mist.port(port_num)
    |> mist.start

  io.println(
    "Ugwo Gleam/BEAM gateway active on 0.0.0.0:" <> int.to_string(port_num),
  )
  process.sleep_forever()
}
