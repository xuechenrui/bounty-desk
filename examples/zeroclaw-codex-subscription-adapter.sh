#!/bin/sh
set -eu

# Adapt ZeroClaw's built-in KiloCLI subprocess provider to `codex exec` while
# enforcing two demo invariants:
#   1. at most one Codex subscription call for the whole agent turn; and
#   2. the model may request only the exact shell command approved beforehand.

die() {
  echo "codex adapter: $*" >&2
  exit 1
}

[ "${1:-}" = '--print' ] || die 'expected ZeroClaw subprocess flag --print'
shift

requested_model=default
if [ "${1:-}" = '--model' ]; then
  [ "$#" -ge 2 ] || die 'missing value after --model'
  requested_model=$2
  shift 2
fi

[ "$#" -eq 1 ] && [ "$1" = '-' ] || die 'expected one stdin marker (-)'

state_dir=${ZEROCLAW_CODEX_ADAPTER_STATE_DIR:-}
allowed_command=${ZEROCLAW_CODEX_ALLOWED_COMMAND:-}
[ -n "$state_dir" ] || die 'ZEROCLAW_CODEX_ADAPTER_STATE_DIR is required'
[ -n "$allowed_command" ] || die 'ZEROCLAW_CODEX_ALLOWED_COMMAND is required'

case "$state_dir" in
  /*) ;;
  *) die 'state directory must be an absolute path' ;;
esac

case "$state_dir" in
  /|"$HOME"|"$PWD") die 'state directory is too broad' ;;
esac

mkdir -p "$state_dir"
claim_dir=$state_dir/codex-call.claimed
status_file=$state_dir/codex-call.status

if ! mkdir "$claim_dir" 2>/dev/null; then
  # ZeroClaw normally asks for one tools-free wrap-up after the shell result.
  # Drain its prompt and answer deterministically without a second Codex call.
  cat >/dev/null
  [ -f "$status_file" ] && [ "$(cat "$status_file")" = completed ] || \
    die 'the one permitted Codex call was already attempted but did not complete'
  printf '%s\n' \
    'The single authorized Codex call has already been used. ZeroClaw executed the validated shell request; use the shell result as the task record.'
  exit 0
fi

printf '%s\n' started >"$status_file"

codex_bin=${CODEX_BIN:-codex}
command -v "$codex_bin" >/dev/null 2>&1 || die "Codex CLI is not executable: $codex_bin"
command -v python3 >/dev/null 2>&1 || die 'python3 is required for strict response validation'

codex_model=${ZEROCLAW_CODEX_MODEL:-$requested_model}
if [ -z "$codex_model" ] || [ "$codex_model" = default ]; then
  codex_model=gpt-5.4-mini
fi

private_workspace=$state_dir/codex-workspace
raw_output=$state_dir/codex-last-message.txt
normalized_output=$state_dir/validated-tool-call.json
output_schema=$state_dir/approved-tool-call.schema.json
mkdir -p "$private_workspace"

# Do not forward the full ZeroClaw transcript into a second agentic runtime.
# The pre-approved command is the only datum Codex needs, and the generated
# schema constrains the final response to that exact value.
cat >/dev/null
python3 - "$output_schema" "$allowed_command" <<'PY'
import json
import pathlib
import sys

schema_path = pathlib.Path(sys.argv[1])
allowed_command = sys.argv[2]
schema = {
    "type": "object",
    "additionalProperties": False,
    "required": ["tool_calls"],
    "properties": {
        "tool_calls": {
            "type": "array",
            "minItems": 1,
            "maxItems": 1,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["name", "arguments"],
                "properties": {
                    "name": {"type": "string", "enum": ["shell"]},
                    "arguments": {
                        "type": "object",
                        "additionalProperties": False,
                        "required": ["command"],
                        "properties": {
                            "command": {
                                "type": "string",
                                "enum": [allowed_command],
                            }
                        },
                    },
                },
            },
        }
    },
}
schema_path.write_text(json.dumps(schema) + "\n", encoding="utf-8")
PY

if ! printf '%s\n' \
  'Return the single JSON object required by the output schema. Do not call tools, inspect files, or add commentary.' | \
  "$codex_bin" exec \
  --ephemeral \
  --sandbox read-only \
  --skip-git-repo-check \
  --ignore-user-config \
  --config 'approval_policy="untrusted"' \
  --config 'web_search="disabled"' \
  --config 'agents.enabled=false' \
  --config 'allow_login_shell=false' \
  --color never \
  --cd "$private_workspace" \
  --model "$codex_model" \
  --output-schema "$output_schema" \
  --output-last-message "$raw_output" \
  - >/dev/null; then
  printf '%s\n' failed >"$status_file"
  die 'Codex CLI call failed; fail-closed marker prevents a retry'
fi

if ! python3 - "$raw_output" "$normalized_output" "$allowed_command" <<'PY'
import json
import pathlib
import sys

raw_path = pathlib.Path(sys.argv[1])
normalized_path = pathlib.Path(sys.argv[2])
allowed_command = sys.argv[3]

try:
    payload = json.loads(raw_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"Codex response is not one JSON object: {exc}")

if not isinstance(payload, dict) or set(payload) != {"tool_calls"}:
    raise SystemExit("Codex response must contain only tool_calls")
calls = payload["tool_calls"]
if not isinstance(calls, list) or len(calls) != 1:
    raise SystemExit("Codex response must contain exactly one tool call")
call = calls[0]
if not isinstance(call, dict) or set(call) != {"name", "arguments"}:
    raise SystemExit("tool call must contain only name and arguments")
if call["name"] != "shell":
    raise SystemExit("only the ZeroClaw shell tool is allowed")
arguments = call["arguments"]
if not isinstance(arguments, dict) or set(arguments) != {"command"}:
    raise SystemExit("shell arguments must contain only command")
if arguments["command"] != allowed_command:
    raise SystemExit("model-proposed command differs from the approved command")

normalized_path.write_text(
    json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8"
)
PY
then
  printf '%s\n' rejected >"$status_file"
  die 'Codex response failed the exact-command policy'
fi

printf '%s\n' completed >"$status_file"
cat "$normalized_output"
