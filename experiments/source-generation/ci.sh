#!/usr/bin/env bash
set -euo pipefail

fixture=experiments/source-generation/fixtures/reserve_stock.rb
evidence="$RUNNER_TEMP/reserve-stock-evidence"
mkdir -p "$evidence"

check() {
  local name="$1" input="$2" expected_status="$3" expected_code="$4"
  local code=0
  KEISIKI_LEAN_OUTPUT="$evidence/$name.lean" \
    bin/check-reserve-stock "$input" > "$evidence/$name.json" || code=$?
  cat "$evidence/$name.json"
  if [[ "$code" != "$expected_code" ]]; then
    echo "$name exited $code, expected $expected_code" >&2
    return 1
  fi
  ruby -rjson -rdigest -e '
    report_path, source_path, expected_status, lean_path = ARGV
    report = JSON.parse(File.read(report_path))
    abort "unexpected report status" unless report.fetch("status") == expected_status
    if File.file?(source_path)
      abort "unexpected source hash" unless report.fetch("source_sha256") == Digest::SHA256.file(source_path).hexdigest
    end
    if %w[proved property_failed].include?(expected_status)
      abort "unexpected Lean hash" unless report.fetch("lean_sha256") == Digest::SHA256.file(lean_path).hexdigest
      theorem = expected_status == "proved" ? "p1_stock_debit" : "p1_counterexample"
      abort "unexpected theorem" unless report.fetch("theorem") == theorem
      output = report.fetch("lean_output")
      abort "missing axiom report" unless output.include?(theorem) && !output.include?("sorryAx")
    else
      abort "unexpected Lean artifact" if File.exist?(lean_path)
    end
  ' "$evidence/$name.json" "$input" "$expected_status" "$evidence/$name.lean"
}

test "$(git hash-object "$fixture")" = 8e2d5eb7f546e9d5698dcf0ae306203334b40422
check pinned "$fixture" proved 0
cp "$fixture" "$RUNNER_TEMP/repeat.rb"
check repeat "$RUNNER_TEMP/repeat.rb" proved 0
cmp "$evidence/pinned.lean" "$evidence/repeat.lean"
cmp "$evidence/pinned.json" "$evidence/repeat.json"

check equivalent experiments/source-generation/fixtures/equivalent.rb proved 0
if cmp -s "$evidence/pinned.lean" "$evidence/equivalent.lean"; then
  echo "different source expressions produced identical Lean" >&2
  exit 1
fi

sed 's/stock.quantity - quantity/stock.quantity + quantity/' "$fixture" > "$RUNNER_TEMP/addition.rb"
check addition "$RUNNER_TEMP/addition.rb" property_failed 1
sed 's/reservation.nil?/true/' "$fixture" > "$RUNNER_TEMP/retry.rb"
check retry "$RUNNER_TEMP/retry.rb" property_failed 1
sed 's/stock.quantity - quantity/stock.quantity.to_i - quantity/' "$fixture" > "$RUNNER_TEMP/method_call.rb"
check method_call "$RUNNER_TEMP/method_call.rb" unsupported 2
sed 's/Stock.lock.find(1)/Stock.find(1)/' "$fixture" > "$RUNNER_TEMP/missing_lock.rb"
check missing_lock "$RUNNER_TEMP/missing_lock.rb" unsupported 2
check missing_input "$RUNNER_TEMP/no-such-reserve-stock.rb" execution_error 2
