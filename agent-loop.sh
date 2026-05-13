#!/usr/bin/env bash
set -uo pipefail

DEFAULT_URL="http://127.0.0.1:8080/v1/chat/completions"
DEFAULT_MODEL="gemma-4-E4b-it.Q4_K_M.gguf"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/config.toml"

RISKY_PATTERNS=("remove-item" "rm " "del " "erase " "set-content" "add-content" "new-item" "move-item" "copy-item" "rename-item" "invoke-webrequest" "iwr " "invoke-restmethod" "irm " "start-process" "stop-process" "set-executionpolicy" ">" ">>")
BASH_RISKY_PATTERNS=(" rm " " rm -" " mv " " cp " " chmod " " chown " " curl " " wget " " tee " ">" ">>")

REQUEST_ARGS=(); CONFIG="$DEFAULT_CONFIG"; MODEL_PROFILE=""; SHELL_NAME_ARG=""; URL_ARG=""; MODEL_ARG=""; CWD_ARG=""; MAX_STEPS_ARG=""; TEMPERATURE_ARG=""; MAX_TOKENS_ARG=""; REQUEST_TIMEOUT_ARG=""; MAX_OUTPUT_CHARS_ARG=""; MAX_OUTPUT_ROWS_ARG=""; MAX_OUTPUT_COLS_ARG=""; SELF_TEST=0; CHAT_MODE=0; ASK_ALWAYS=0; AUTO_RUN_ALL=0
MODEL_PROFILE_RESOLVED=""; MODEL_PROVIDER=""; MODEL_URL=""; MODEL_NAME=""; MODEL_TEMPERATURE=""; MODEL_MAX_TOKENS=""; MODEL_REQUEST_TIMEOUT=""; MODEL_API_KEY_ENV=""
SHELL_NAME=""; SHELL_TOOL=""; SHELL_PROMPT_PATH=""; SHELL_EXECUTABLE=""; SHELL_ARGS=()
AGENT_CWD=""; AGENT_MAX_STEPS=""; AGENT_MAX_OUTPUT_CHARS=""; AGENT_MAX_OUTPUT_ROWS=""; AGENT_MAX_OUTPUT_COLS=""; MESSAGES_JSON="[]"

usage(){ cat <<EOF
usage: $(basename "$0") [options] [request...]
  --config PATH --model-profile NAME --shell powershell|bash --url URL --model NAME
  --cwd PATH --max-steps N --temperature FLOAT --max-tokens N --request-timeout N
  --max-output-chars N --max-output-rows N --max-output-cols N
  --self-test --chat --ask-always --auto-run-all
EOF
}
die(){ echo "$*" >&2; exit 2; }

parse_args(){ while (($#)); do case "$1" in
  --config) shift||die "--config requires a value"; CONFIG="$1";;
  --model-profile) shift||die "--model-profile requires a value"; MODEL_PROFILE="$1";;
  --shell) shift||die "--shell requires a value"; [[ "$1" =~ ^(powershell|bash)$ ]]||die "--shell must be one of: powershell, bash"; SHELL_NAME_ARG="$1";;
  --url) shift||die "--url requires a value"; URL_ARG="$1";;
  --model) shift||die "--model requires a value"; MODEL_ARG="$1";;
  --cwd) shift||die "--cwd requires a value"; CWD_ARG="$1";;
  --max-steps) shift||die "--max-steps requires a value"; MAX_STEPS_ARG="$1";;
  --temperature) shift||die "--temperature requires a value"; TEMPERATURE_ARG="$1";;
  --max-tokens) shift||die "--max-tokens requires a value"; MAX_TOKENS_ARG="$1";;
  --request-timeout) shift||die "--request-timeout requires a value"; REQUEST_TIMEOUT_ARG="$1";;
  --max-output-chars) shift||die "--max-output-chars requires a value"; MAX_OUTPUT_CHARS_ARG="$1";;
  --max-output-rows) shift||die "--max-output-rows requires a value"; MAX_OUTPUT_ROWS_ARG="$1";;
  --max-output-cols) shift||die "--max-output-cols requires a value"; MAX_OUTPUT_COLS_ARG="$1";;
  --self-test) SELF_TEST=1;; --chat) CHAT_MODE=1;;
  --ask-always) ((AUTO_RUN_ALL))&&die "--ask-always and --auto-run-all are mutually exclusive"; ASK_ALWAYS=1;;
  --auto-run-all) ((ASK_ALWAYS))&&die "--ask-always and --auto-run-all are mutually exclusive"; AUTO_RUN_ALL=1;;
  -h|--help) usage; exit 0;; --) shift; REQUEST_ARGS+=("$@"); break;; -*) die "Unknown option: $1";; *) REQUEST_ARGS+=("$1");;
esac; shift || true; done; }

trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
strip_quotes(){ local s; s="$(trim "$1")"; if [[ "$s" =~ ^\"(.*)\"$ ]]; then printf '%s' "${BASH_REMATCH[1]}"; elif [[ "$s" =~ ^\'(.*)\'$ ]]; then printf '%s' "${BASH_REMATCH[1]}"; else printf '%s' "$s"; fi; }
to_lower(){ tr '[:upper:]' '[:lower:]'; }
realpath_maybe(){ if command -v realpath >/dev/null 2>&1; then realpath -m "$1"; else (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$PWD" "$(basename "$1")") || printf '%s\n' "$1"; fi; }
resolve_path(){ local p="$1" b="$2"; p="${p/#\~/$HOME}"; [[ "$p" == /* ]] && realpath_maybe "$p" || realpath_maybe "$b/$p"; }

escape_ere(){ sed 's/[][\.\*^$()+?{}|]/\\&/g' <<<"$1"; }
toml_has_section(){ local re; re="$(escape_ere "$2")"; [[ -f "$1" ]] && grep -Eq "^[[:space:]]*\[$re\][[:space:]]*$" "$1"; }
toml_get(){ local file="$1" section="$2" key="$3"; [[ -f "$file" ]]||return 1; awk -v target="$section" -v key="$key" '
function trim(s){gsub(/^[ \t\r\n]+/,"",s);gsub(/[ \t\r\n]+$/, "", s);return s}
function unquote(s){s=trim(s); if(s ~ /^".*"$/ || s ~ /^'\''.*'\''$/) return substr(s,2,length(s)-2); return s}
BEGIN{in_section=0} /^[[:space:]]*#/ || /^[[:space:]]*$/ {next} /^[[:space:]]*\[/ {line=trim($0);gsub(/^\[/,"",line);gsub(/\]$/,"",line);in_section=(line==target);next}
in_section{line=$0; sub(/[[:space:]]+#.*$/,"",line); eq=index(line,"="); if(eq==0) next; k=trim(substr(line,1,eq-1)); v=trim(substr(line,eq+1)); if(k==key){print unquote(v); exit 0}}
' "$file"; }
toml_array_get(){ local raw item current="" in_quote=0 quote_char="" out=(); raw="$(toml_get "$1" "$2" "$3" || true)"; raw="$(trim "$raw")"; [[ "$raw" == \[*\] ]]||return 0; raw="${raw#[}"; raw="${raw%]}"; local i ch; for ((i=0;i<${#raw};i++)); do ch="${raw:i:1}"; if ((in_quote)); then if [[ "$ch" == "$quote_char" ]]; then in_quote=0; else current+="$ch"; fi; else case "$ch" in "'"|'"') in_quote=1; quote_char="$ch";; ,) item="$(trim "$current")"; [[ -n "$item" ]]&&out+=("$(strip_quotes "$item")"); current="";; *) current+="$ch";; esac; fi; done; item="$(trim "$current")"; [[ -n "$item" ]]&&out+=("$(strip_quotes "$item")"); printf '%s\n' "${out[@]}"; }
config_value(){ local arg="$1" file="$2" section="$3" attr="$4" def="$5" value key_hyphen; [[ -n "$arg" ]]&&{ printf '%s' "$arg"; return; }; key_hyphen="${attr//_/-}"; value="$(toml_get "$file" "$section" "$key_hyphen" || true)"; [[ -n "$value" ]]&&{ printf '%s' "$value"; return; }; value="$(toml_get "$file" "$section" "$attr" || true)"; [[ -n "$value" ]]&&{ printf '%s' "$value"; return; }; printf '%s' "$def"; }

load_agent_config(){ local config_path config_base has_models=0 model_section shell_section prompt_value; config_path="$(resolve_path "$CONFIG" "$PWD")"; CONFIG="$config_path"; config_base="$(dirname "$config_path")"; [[ -f "$CONFIG" ]]&&grep -Eq '^[[:space:]]*\[models\.' "$CONFIG"&&has_models=1
MODEL_PROFILE_RESOLVED="$MODEL_PROFILE"; [[ -z "$MODEL_PROFILE_RESOLVED" ]]&&MODEL_PROFILE_RESOLVED="$(toml_get "$CONFIG" agent model_profile 2>/dev/null || true)"; [[ -z "$MODEL_PROFILE_RESOLVED" ]]&&MODEL_PROFILE_RESOLVED=local
if ((has_models)); then model_section="models.$MODEL_PROFILE_RESOLVED"; toml_has_section "$CONFIG" "$model_section"||{ echo "Model profile '$MODEL_PROFILE_RESOLVED' is not defined in $CONFIG." >&2; return 1; }; else model_section=model; [[ "$MODEL_PROFILE_RESOLVED" == local ]]||{ echo "Model profile '$MODEL_PROFILE_RESOLVED' is not defined in $CONFIG." >&2; return 1; }; fi
SHELL_NAME="$SHELL_NAME_ARG"; [[ -z "$SHELL_NAME" ]]&&SHELL_NAME="$(toml_get "$CONFIG" agent shell 2>/dev/null || true)"; [[ -z "$SHELL_NAME" ]]&&SHELL_NAME=powershell; shell_section="shells.$SHELL_NAME"; toml_has_section "$CONFIG" "$shell_section"||{ echo "Shell profile '$SHELL_NAME' is not defined in $CONFIG." >&2; return 1; }
prompt_value="$(toml_get "$CONFIG" "$shell_section" prompt || true)"; [[ -n "$prompt_value" ]]||{ echo "Shell profile '$SHELL_NAME' must define a prompt path." >&2; return 1; }
SHELL_TOOL="$(toml_get "$CONFIG" "$shell_section" tool || true)"; [[ -z "$SHELL_TOOL" ]]&&SHELL_TOOL="$SHELL_NAME"; SHELL_PROMPT_PATH="$(resolve_path "$prompt_value" "$config_base")"; SHELL_EXECUTABLE="$(toml_get "$CONFIG" "$shell_section" executable || true)"; [[ -z "$SHELL_EXECUTABLE" ]]&&SHELL_EXECUTABLE="$SHELL_NAME"; mapfile -t SHELL_ARGS < <(toml_array_get "$CONFIG" "$shell_section" args)
MODEL_PROVIDER="$(toml_get "$CONFIG" "$model_section" provider || true)"; [[ -z "$MODEL_PROVIDER" ]]&&MODEL_PROVIDER=openai-chat; MODEL_URL="$(config_value "$URL_ARG" "$CONFIG" "$model_section" url "$DEFAULT_URL")"; MODEL_NAME="$(config_value "$MODEL_ARG" "$CONFIG" "$model_section" model "$DEFAULT_MODEL")"; MODEL_TEMPERATURE="$(config_value "$TEMPERATURE_ARG" "$CONFIG" "$model_section" temperature 0.0)"; MODEL_MAX_TOKENS="$(config_value "$MAX_TOKENS_ARG" "$CONFIG" "$model_section" max_tokens 1024)"; MODEL_REQUEST_TIMEOUT="$(config_value "$REQUEST_TIMEOUT_ARG" "$CONFIG" "$model_section" request_timeout 600)"; MODEL_API_KEY_ENV="$(toml_get "$CONFIG" "$model_section" api_key_env || true)"
AGENT_CWD="$(config_value "$CWD_ARG" "$CONFIG" agent cwd .)"; AGENT_MAX_STEPS="$(config_value "$MAX_STEPS_ARG" "$CONFIG" agent max_steps 5)"; AGENT_MAX_OUTPUT_CHARS="$(config_value "$MAX_OUTPUT_CHARS_ARG" "$CONFIG" agent max_output_chars 20000)"; AGENT_MAX_OUTPUT_ROWS="$(config_value "$MAX_OUTPUT_ROWS_ARG" "$CONFIG" agent max_output_rows 250)"; AGENT_MAX_OUTPUT_COLS="$(config_value "$MAX_OUTPUT_COLS_ARG" "$CONFIG" agent max_output_cols 400)"; }

build_headers_array(){ HEADERS_ARRAY=(-H "Content-Type: application/json"); if [[ -n "$MODEL_API_KEY_ENV" ]]; then local api_key="${!MODEL_API_KEY_ENV:-}"; [[ -n "$api_key" ]]||{ echo "Model profile '$MODEL_PROFILE_RESOLVED' requires \$$MODEL_API_KEY_ENV, but that environment variable is not set." >&2; return 1; }; [[ "$MODEL_PROVIDER" == google-gemini ]]&&HEADERS_ARRAY+=(-H "x-goog-api-key: $api_key")||HEADERS_ARRAY+=(-H "Authorization: Bearer $api_key"); fi; }
messages_add(){ MESSAGES_JSON="$(jq -c --arg role "$1" --arg content "$2" '. + [{role:$role, content:$content}]' <<<"$MESSAGES_JSON")"; }
chat(){ [[ "$MODEL_PROVIDER" == google-gemini ]]&&chat_google_gemini||{ [[ "$MODEL_PROVIDER" == openai-chat ]]||{ echo "Unsupported model provider for profile '$MODEL_PROFILE_RESOLVED': $MODEL_PROVIDER" >&2; return 1; }; chat_openai_compatible; }; }
chat_openai_compatible(){ local payload raw http temp; payload="$(jq -cn --arg model "$MODEL_NAME" --argjson messages "$MESSAGES_JSON" --argjson temperature "$MODEL_TEMPERATURE" --argjson max_tokens "$MODEL_MAX_TOKENS" '{model:$model,messages:$messages,temperature:$temperature,max_tokens:$max_tokens}')"; build_headers_array||return 1; temp="$(mktemp)"; http="$(curl -sS --max-time "$MODEL_REQUEST_TIMEOUT" -w '%{http_code}' -o "$temp" -X POST "${HEADERS_ARRAY[@]}" --data-binary "$payload" "$MODEL_URL")"; local st=$?; raw="$(cat "$temp")"; rm -f "$temp"; ((st==0))||{ echo "Could not reach model endpoint: curl exited with status $st" >&2; return 1; }; [[ "$http" =~ ^[45] ]]&&{ echo "HTTP $http: $raw" >&2; return 1; }; jq -er '.choices[0].message.content' <<<"$raw"; }
build_google_payload(){ jq -cn --argjson messages "$MESSAGES_JSON" --argjson temperature "$MODEL_TEMPERATURE" --argjson max_tokens "$MODEL_MAX_TOKENS" 'def part($t):{text:$t}; {contents:[$messages[]|select(.role!="system")|{role:(if .role=="assistant" then "model" else "user" end),parts:[part(.content)]}],generationConfig:{temperature:$temperature,maxOutputTokens:$max_tokens}} as $base | ([$messages[]|select(.role=="system")|part(.content)]) as $sys | if ($sys|length)>0 then $base+{systemInstruction:{parts:$sys}} else $base end'; }
recover_google_malformed_tool_call(){ local prefix="Malformed function call:" body; [[ "$1" == "$prefix"* ]]||return 0; body="$(trim "${1#"$prefix"}")"; shopt -s nocasematch; [[ "$body" == call:* ]]&&printf '<|tool_call>%s' "$body"||printf '%s' "$body"; shopt -u nocasematch; }
chat_google_gemini(){ local payload raw http temp url body reason msg rec; url="${MODEL_URL%/}/${MODEL_NAME}:generateContent"; payload="$(build_google_payload)"; build_headers_array||return 1; temp="$(mktemp)"; http="$(curl -sS --max-time "$MODEL_REQUEST_TIMEOUT" -w '%{http_code}' -o "$temp" -X POST "${HEADERS_ARRAY[@]}" --data-binary "$payload" "$url")"; local st=$?; raw="$(cat "$temp")"; rm -f "$temp"; ((st==0))||{ echo "Could not reach model endpoint: curl exited with status $st" >&2; return 1; }; [[ "$http" =~ ^[45] ]]&&{ echo "HTTP $http: $raw" >&2; return 1; }; body="$(jq -r '[.candidates[0].content.parts[]?.text // empty] | join("")' <<<"$raw")"; if [[ -z "$body" ]]; then reason="$(jq -r '.candidates[0].finishReason // empty' <<<"$raw")"; msg="$(jq -r '.candidates[0].finishMessage // empty' <<<"$raw")"; [[ "$reason" == MALFORMED_FUNCTION_CALL ]]&&{ rec="$(recover_google_malformed_tool_call "$msg")"; [[ -n "$rec" ]]&&{ printf '%s' "$rec"; return; }; }; echo "Google Gemini response did not contain text: ${raw:0:1000}" >&2; return 1; fi; printf '%s' "$body"; }

extract_tool_call(){ local text="$1" rest body tool command had=0; [[ "$text" =~ \<\|tool_call\>[[:space:]]*call:([A-Za-z0-9_.:-]+) ]]||return 1; tool="${BASH_REMATCH[1]}"; rest="${text#*call:$tool}"; body="$rest"; body="${body%%<tool_call|>*}"; body="${body%%<|tool_call|>*}"; if [[ "$body" == *"<|tool_call>"* ]]; then body="${body%%<|tool_call>*}"; had=1; fi; command="$(trim "$body")"; if [[ "$command" == \`* && "$command" == *\` ]]; then command="${command:1:${#command}-2}"; command="$(trim "$command")"; fi; printf '%s\t%s\t%s' "$tool" "$command" "$had"; }
has_tool_call_start(){ [[ "$1" =~ \<\|tool_call\>[[:space:]]*call:([A-Za-z0-9_.:-]+) ]]; }
looks_risky(){ local lowered=" $(printf '%s' "$1"|to_lower) " p; for p in "${RISKY_PATTERNS[@]}"; do [[ "$lowered" == *"$p"* ]]&&return 0; done; return 1; }
looks_risky_for_shell(){ local lowered=" $(printf '%s' "$1"|to_lower) " p; if [[ "$2" == bash ]]; then for p in "${BASH_RISKY_PATTERNS[@]}"; do [[ "$lowered" == *"$p"* ]]&&return 0; done; return 1; fi; looks_risky "$1"; }
uses_fragile_powershell_script_write(){ local command="$1" lowered; lowered="$(printf '%s' "$command"|to_lower)"; [[ "$lowered" == *".py"* || "$lowered" == *".ps1"* ]]||return 1; [[ "$lowered" == *set-content* ]]||return 1; [[ "$lowered" == *" -value "* ]]&&return 0; [[ "$command" == *"@'"* || "$command" == *'@"'* ]]&&return 1; if [[ "$lowered" == *get-content* && ( "$lowered" == *" -replace "* || "$lowered" == *".replace("* ) ]]; then return 1; fi; [[ "$command" == *"|"* ]]; }
uses_fragile_bash_script_write(){ local command="$1" lowered; lowered="$(printf '%s' "$command"|to_lower)"; [[ "$lowered" == *".py"* || "$lowered" == *".ps1"* || "$lowered" == *".sh"* ]]||return 1; [[ "$command" == *"<<"* ]]&&return 1; [[ "$lowered" == *python* && "$lowered" == *".replace("* ]]&&return 1; [[ "$command" =~ (^|[[:space:]])echo[[:space:]].*\>{1,2}[[:space:]]*[^[:space:]]+\.(py|ps1|sh) ]]; }
uses_fragile_script_write(){ [[ "$2" == bash ]]&&uses_fragile_bash_script_write "$1"||uses_fragile_powershell_script_write "$1"; }
should_run(){ if ((AUTO_RUN_ALL)); then return 0; fi; if ((ASK_ALWAYS)) || looks_risky_for_shell "$1" "$2"; then echo -e "\n$2 command proposed:\n\n$1"; local answer; read -r -p "Run this command? [y/N] " answer||{ echo "No interactive input available; command was not run."; return 1; }; answer="$(printf '%s' "$answer"|to_lower)"; [[ "$answer" == y || "$answer" == yes ]]; else return 0; fi; }
needs_recursive_search(){ local x; x="$(printf '%s' "$1"|to_lower)"; [[ "$x" == *subfolder* || "$x" == *subfolders* || "$x" == *recursive* || "$x" == *recursively* || "$x" == *"under this folder"* ]]; }
load_prompt(){ [[ -f "$1" ]]||{ echo "System prompt file does not exist: $1" >&2; return 1; }; sed -e '${/^$/d;}' "$1"; }
build_initial_user_prompt(){ local request="$1" system_prompt="$2" hint="" current_date; needs_recursive_search "$request"&&hint=$'\n\nImportant: this request asks about subfolders or items under this folder. Use the recursive search option for the configured shell command.'; current_date="$(date +%F)"; cat <<EOF
$system_prompt

Current date: $current_date

User request: $request$hint

When you need the shell tool, return one complete call in this exact form:
<|tool_call>call:$SHELL_TOOL
$SHELL_NAME command here
<tool_call|>

Return at most one call:$SHELL_TOOL block per response. Wait for the tool result before making another call. The call:$SHELL_TOOL body must be only the command needed to inspect or modify the system. Do not include analysis, summaries, markdown, comments, or invented results inside the block. If the request asks about command output, run that command first. If the request asks you to create, modify, fix, or debug a text file, inspect first, make the smallest useful edit, then verify by reading the file back and rerunning the relevant command. When creating a script, do not give the final answer immediately after writing it; first read it back and run it when the command is non-destructive. When asked to write a script that uses a local helper module, do not modify the helper module unless the user explicitly asks. If verification fails, adjust the generated script or its inputs first. If a generated URL or path returns not found, test small variants derived from the user's exact spelling, including preserved punctuation, dots, hyphens, and removed punctuation, then update and rerun the script.
EOF
}
run_shell(){ local command="$1" cwd="$2" exe="$SHELL_EXECUTABLE" out err; command -v "$exe" >/dev/null 2>&1&&exe="$(command -v "$exe")"; out="$(mktemp)"; err="$(mktemp)"; (cd "$cwd" && timeout 120 "$exe" "${SHELL_ARGS[@]}" "$command") >"$out" 2>"$err"; RUN_SHELL_EXIT_CODE=$?; RUN_SHELL_STDOUT="$(cat "$out")"; RUN_SHELL_STDERR="$(cat "$err")"; rm -f "$out" "$err"; }
trim_text(){ local text="$1" max="$2" head tail omitted; if (( max<=0 || ${#text}<=max )); then printf '%s' "$text"; return; fi; head=$((max/2)); tail=$((max-head)); omitted=$((${#text}-max)); printf '%s\n\n... <omitted %s characters from the middle> ...\n\n%s' "${text:0:head}" "$omitted" "${text: -tail}"; }
reduce_text_by_rows_and_cols(){ local text="$1" max_rows="$2" max_cols="$3" outv="$4" rowsv="$5" colsv="$6" rows_removed=0 cols_removed=0; mapfile -t lines <<<"$text"; [[ -z "$text" ]]&&lines=(); if ((max_rows>0 && ${#lines[@]}>max_rows)); then rows_removed=$((${#lines[@]}-max_rows)); local head=$((max_rows/2)) tail=$((max_rows-head)) tmp=() i start; for((i=0;i<head;i++));do tmp+=("${lines[i]}");done; tmp+=("... <omitted $rows_removed rows from the middle> ..."); start=$((${#lines[@]}-tail)); for((i=start;i<${#lines[@]};i++));do tmp+=("${lines[i]}");done; lines=("${tmp[@]}"); fi; local reduced=() line omitted headc tailc; for line in "${lines[@]}"; do if ((max_cols>0 && ${#line}>max_cols)); then omitted=$((${#line}-max_cols)); cols_removed=$((cols_removed+omitted)); headc=$((max_cols/2)); tailc=$((max_cols-headc)); reduced+=("${line:0:headc} ... <omitted $omitted columns> ... ${line: -tailc}"); else reduced+=("$line"); fi; done; local joined=""; ((${#reduced[@]}))&&printf -v joined '%s\n' "${reduced[@]}"&&joined="${joined%$'\n'}"; printf -v "$outv" '%s' "$joined"; printf -v "$rowsv" '%s' "$rows_removed"; printf -v "$colsv" '%s' "$cols_removed"; }
build_recovery_hint(){ local text; text="$(printf '%s\n%s\n%s' "$1" "$2" "$3"|to_lower)"; if [[ "$text" == *"status code: 404"* || "$text" == *" 404"* || "$text" == *"existiert leider nicht"* || "$text" == *"page does not exist"* ]]; then printf '\n\nThe last check appears to have found an invalid URL or missing page. Before finalizing, debug the URL generically: test small URL variants derived from the user'"'"'s exact spelling, including preserved punctuation, dots, hyphens, and removed punctuation. Prefer the variant that returns a normal result page, then update and rerun the script.'; elif [[ "$text" == *"list index out of range"* ]]; then printf '\n\nThe last script likely parsed an unexpected or empty page. Inspect the input data or URL it used, print the relevant status/heading/content shape, then update and rerun the script.'; fi; }
format_tool_result(){ local command="$1" exit_code="$2" stdout="$3" stderr="$4" tool="$5" req="$6" sr srr scr er err ecr hint; reduce_text_by_rows_and_cols "$stdout" "$AGENT_MAX_OUTPUT_ROWS" "$AGENT_MAX_OUTPUT_COLS" sr srr scr; reduce_text_by_rows_and_cols "$stderr" "$AGENT_MAX_OUTPUT_ROWS" "$AGENT_MAX_OUTPUT_COLS" er err ecr; stdout="$(trim_text "$sr" "$AGENT_MAX_OUTPUT_CHARS")"; stderr="$(trim_text "$er" "$AGENT_MAX_OUTPUT_CHARS")"; hint="$(build_recovery_hint "$command" "$stdout" "$stderr" "$req")"; cat <<EOF
<|tool_result>call:$tool
Command:
$command

Exit code: $exit_code

Reduction summary:
STDOUT removed rows: $srr, removed columns: $scr
STDERR removed rows: $err, removed columns: $ecr

STDOUT:
${stdout:-<empty>}

STDERR:
${stderr:-<empty>}

<tool_result|>

Use this result to answer the original user request. If more inspection is needed, call $tool again.$hint
EOF
}
run_agent_turn(){ local request="$1" cwd="$2" step assistant parsed tool command had result stdout_reduced stdout_rows_removed stdout_cols_removed stderr_reduced stderr_rows_removed stderr_cols_removed; for((step=1;step<=AGENT_MAX_STEPS;step++)); do echo -e "\n--- model step $step ---"; assistant="$(chat)"||return 1; echo "$assistant"; if [[ -z "$(trim "$assistant")" ]]; then messages_add user "Your previous answer was empty. Return either one complete <|tool_call>call:$SHELL_TOOL tool call for inspection or a final plain-text answer."; continue; fi; messages_add assistant "$assistant"; parsed="$(extract_tool_call "$assistant" || true)"; if [[ -z "$parsed" ]]; then if has_tool_call_start "$assistant"; then messages_add user "The tool call was malformed. Use exactly this format if more inspection is needed:
<|tool_call>call:$SHELL_TOOL
$SHELL_NAME command here
<tool_call|>
Otherwise return the final answer in plain text."; continue; fi; return 0; fi; IFS=$'\t' read -r tool command had <<<"$parsed"; [[ "$(printf '%s' "$tool"|to_lower)" == "$(printf '%s' "$SHELL_TOOL"|to_lower)" ]]||{ messages_add user "Unsupported tool call: call:$tool. Only call:$SHELL_TOOL is available. Use call:$SHELL_TOOL for shell inspection or return the final answer in plain text."; continue; }; [[ -n "$command" ]]||{ messages_add user "The call:$SHELL_TOOL tool call did not contain a command. Resend one complete call:$SHELL_TOOL tool call with the command body, or return the final answer."; continue; }; if uses_fragile_script_write "$command" "$SHELL_NAME"; then [[ "$SHELL_NAME" == powershell ]]&&rh="use a PowerShell here-string piped to Set-Content -Encoding UTF8"||rh="use a quoted Bash here-doc such as cat > file.py <<'PY'"; messages_add user "Do not write script bodies with fragile single-line redirection or quoted pipeline strings. Resend exactly one call:$SHELL_TOOL command that uses $rh, then wait for the tool result."; continue; fi; should_run "$command" "$SHELL_NAME"||{ echo "Command skipped by user."; return 1; }; echo -e "\n--- $SHELL_NAME step $step ---"; echo "$command"; run_shell "$command" "$cwd"; echo "Exit code: $RUN_SHELL_EXIT_CODE"; reduce_text_by_rows_and_cols "$RUN_SHELL_STDOUT" "$AGENT_MAX_OUTPUT_ROWS" "$AGENT_MAX_OUTPUT_COLS" stdout_reduced stdout_rows_removed stdout_cols_removed; reduce_text_by_rows_and_cols "$RUN_SHELL_STDERR" "$AGENT_MAX_OUTPUT_ROWS" "$AGENT_MAX_OUTPUT_COLS" stderr_reduced stderr_rows_removed stderr_cols_removed; [[ -n "$stdout_reduced" ]]&&{ echo "[Reduced STDOUT context]"; echo "removed rows=$stdout_rows_removed, removed columns=$stdout_cols_removed"; trim_text "$stdout_reduced" "$AGENT_MAX_OUTPUT_CHARS"; echo; }; [[ -n "$stderr_reduced" ]]&&{ echo "[Reduced STDERR context]" >&2; echo "removed rows=$stderr_rows_removed, removed columns=$stderr_cols_removed" >&2; trim_text "$stderr_reduced" "$AGENT_MAX_OUTPUT_CHARS" >&2; echo >&2; }; result="$(format_tool_result "$command" "$RUN_SHELL_EXIT_CODE" "$RUN_SHELL_STDOUT" "$RUN_SHELL_STDERR" "$SHELL_TOOL" "$request")"; [[ "$had" == 1 ]]&&result+=$'\n\nYour previous response contained more than one tool call. Only the first tool call was executed. If another command is still needed, send exactly one new call:'"$SHELL_TOOL"$' now. Do not claim that skipped commands ran.'; messages_add user "$result"; done; echo -e "\nStopped after --max-steps=$AGENT_MAX_STEPS." >&2; return 1; }

assert_fragile(){ local shell="$1" command="$2" expected="$3" actual=False; uses_fragile_script_write "$command" "$shell"&&actual=True; [[ "$actual" == "$expected" ]]||{ echo "FAIL: expected $expected, got $actual: $shell: $command" >&2; return 1; }; }
assert_parse(){ local text="$1" expected_tool="$2" expected_command="$3" parsed tool command had; parsed="$(extract_tool_call "$text"||true)"; IFS=$'\t' read -r tool command had <<<"$parsed"; [[ "$tool" == "$expected_tool" && "$command" == "$expected_command" ]]||{ echo "FAIL: expected $expected_tool/$expected_command, got $tool/$command: $text" >&2; return 1; }; }
run_config_self_tests(){ local failures=0 td old_config old_profile old_model; td="$(mktemp -d)"; cat >"$td/config.toml" <<'EOF'
[agent]
model_profile = "local"
shell = "powershell"
cwd = "."
max_steps = 5
max_output_chars = 20000
[models.local]
url = "http://localhost/local"
model = "local-model"
temperature = 0.0
max_tokens = 111
request_timeout = 222
[models.openrouter-minimax-free]
url = "https://openrouter.ai/api/v1/chat/completions"
provider = "openai-chat"
model = "minimax/minimax-m2.5:free"
api_key_env = "OPENROUTER_API_KEY"
temperature = 0.0
max_tokens = 2048
request_timeout = 120
[models.google-gemma-free]
url = "https://generativelanguage.googleapis.com/v1beta"
provider = "google-gemini"
model = "models/gemma-4-26b-a4b-it"
api_key_env = "GEMINI_API_KEY"
temperature = 0.0
max_tokens = 2048
request_timeout = 120
[shells.powershell]
tool = "ps"
prompt = "SYSTEM.md"
executable = "powershell.exe"
args = ["-NoProfile", "-Command"]
EOF
old_config="$CONFIG"; old_profile="$MODEL_PROFILE"; old_model="$MODEL_ARG"; CONFIG="$td/config.toml"; MODEL_PROFILE=""; MODEL_ARG=""; load_agent_config >/dev/null || failures=$((failures+1)); [[ "$MODEL_PROFILE_RESOLVED/$MODEL_NAME" == local/local-model ]]||{ echo "FAIL: local profile" >&2; failures=$((failures+1)); }; MODEL_PROFILE=openrouter-minimax-free; MODEL_ARG=""; load_agent_config >/dev/null || failures=$((failures+1)); [[ "$MODEL_NAME" == minimax/minimax-m2.5:free ]]||{ echo "FAIL: openrouter profile" >&2; failures=$((failures+1)); }; MODEL_PROFILE=google-gemma-free; load_agent_config >/dev/null || failures=$((failures+1)); [[ "$MODEL_PROVIDER/$MODEL_NAME" == google-gemini/models/gemma-4-26b-a4b-it ]]||{ echo "FAIL: google profile" >&2; failures=$((failures+1)); }; MODEL_PROFILE=openrouter-minimax-free; MODEL_ARG=override/model:free; load_agent_config >/dev/null || failures=$((failures+1)); [[ "$MODEL_NAME" == override/model:free ]]||{ echo "FAIL: model override" >&2; failures=$((failures+1)); }; CONFIG="$old_config"; MODEL_PROFILE="$old_profile"; MODEL_ARG="$old_model"; rm -rf "$td"; return "$failures"; }
run_self_test(){ local failures=0; assert_fragile powershell "Set-Content -Path 'hello.py' -Value 'print(\"hello\")' -Encoding UTF8" True || failures=$((failures+1)); assert_fragile powershell "'print(\"hello\")' | Set-Content -Path hello.py -Encoding UTF8" True || failures=$((failures+1)); assert_fragile powershell $'@\'\nprint("hello")\n\'@ | Set-Content -Path hello.py -Encoding UTF8' False || failures=$((failures+1)); assert_fragile powershell "(Get-Content -Raw buggy.py).Replace('a + c', 'a + b') | Set-Content -Path buggy.py -Encoding UTF8" False || failures=$((failures+1)); assert_fragile powershell "(Get-Content -Raw buggy.py) -replace 'a \\+ c', 'a + b' | Set-Content -Path buggy.py -Encoding UTF8" False || failures=$((failures+1)); assert_fragile powershell "Get-ChildItem -Filter *.py" False || failures=$((failures+1)); assert_fragile bash "echo 'print(\"hello\")' > hello.py" True || failures=$((failures+1)); assert_fragile bash $'cat > hello.py <<\'PY\'\nprint("hello")\nPY' False || failures=$((failures+1)); assert_fragile bash $'python3 - <<\'PY\'\nfrom pathlib import Path\nPath(\'buggy.py\').write_text(Path(\'buggy.py\').read_text().replace(\'a + c\', \'a + b\'))\nPY' False || failures=$((failures+1)); assert_parse $'<|tool_call>call:ps\nGet-ChildItem\n<tool_call|>' ps Get-ChildItem || failures=$((failures+1)); assert_parse $'<|tool_call>call:ps\nGet-Location\n<|tool_call|>' ps Get-Location || failures=$((failures+1)); assert_parse $'<|tool_call>call:bash\nls -la\n<tool_call|>' bash 'ls -la' || failures=$((failures+1)); run_config_self_tests || failures=$((failures+1)); ((failures==0))&&{ echo "self-test ok"; return 0; }; return 1; }

main(){ parse_args "$@"; ((SELF_TEST))&&{ run_self_test; return $?; }; command -v jq >/dev/null 2>&1||die "jq is required."; command -v curl >/dev/null 2>&1||die "curl is required."; command -v timeout >/dev/null 2>&1||die "timeout is required."; load_agent_config||return 2; local system_prompt request cwd status; system_prompt="$(load_prompt "$SHELL_PROMPT_PATH")"||return 2; request="$(trim "${REQUEST_ARGS[*]}")"; [[ -z "$request" ]]&&read -r -p "User request: " request; request="$(trim "$request")"; [[ -n "$request" ]]||{ echo "No request provided." >&2; return 2; }; cwd="$(resolve_path "$AGENT_CWD" "$PWD")"; [[ -d "$cwd" ]]||{ echo "Working directory does not exist or is not a directory: $cwd" >&2; return 2; }; command -v "$SHELL_EXECUTABLE" >/dev/null 2>&1 || [[ -x "$SHELL_EXECUTABLE" ]] || { echo "Configured shell executable was not found for '$SHELL_NAME': $SHELL_EXECUTABLE" >&2; return 2; }; MESSAGES_JSON=[]; messages_add system "$system_prompt"; messages_add user "$(build_initial_user_prompt "$request" "$system_prompt")"; while true; do run_agent_turn "$request" "$cwd"; status=$?; ((status!=0 || CHAT_MODE==0))&&return "$status"; read -r -p $'\nFollow-up request [empty to exit]: ' request||return 0; request="$(trim "$request")"; [[ -z "$request" || "$(printf '%s' "$request"|to_lower)" =~ ^(exit|quit)$ ]]&&return 0; messages_add user "User follow-up request: $request"; done; }
main "$@"
