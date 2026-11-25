require "json"

def retry_result(path, control, expected_status)
  result = JSON.parse(File.read(path))
  violations = result.fetch("violations", [])
  observed = result.fetch("observed", {})
  outcome = case result.fetch("status")
  when "MATCH"
    violations.empty? ? "not_detected" : "execution_error"
  when "CONTRACT_VIOLATION"
    violations == ["retry_stock_unchanged"] ? "detected" : "execution_error"
  else
    "execution_error"
  end

  {
    property: "P1",
    method: "実行履歴の照合",
    case: control == "normal" ? "正常版" : "再送時の二重更新",
    role: control,
    expected: expected_status,
    observed: outcome,
    assurance: outcome == "execution_error" ? "unchecked" : "execution_check",
    target: "Rails HTTP・PostgreSQL の確定結果",
    assumptions: "初回コミット後に応答が失われ、再送までに他の書き込みがない",
    scope: "初期在庫２、同一予約 ID・数量１で再送１回",
    checker: "test/retry_contract.rb",
    evidence: {
      status: result.fetch("status"),
      violations: violations,
      expected_stock_after_retry: result.dig("expected", "stock_after_reservation"),
      stock_after_first_commit: observed["stock_after_first_commit"],
      stock_after_retry: observed["stock_after_retry"],
      reason: result["reason"]
    },
    trials: 1,
    trial_budget: nil,
    duration_ms: nil,
    time_budget_ms: nil,
    replay_steps: nil
  }
end

abort "Usage: ruby reporting/import_retry.rb RUN_URL BASELINE.json DOUBLE_UPDATE.json" unless ARGV.size == 3

source, baseline, double_update = ARGV
puts JSON.pretty_generate(
  version: 1,
  source: source,
  rows: [
    retry_result(baseline, "normal", "not_detected"),
    retry_result(double_update, "positive_control", "detected")
  ]
)
