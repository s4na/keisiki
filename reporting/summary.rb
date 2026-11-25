require "json"

OUTCOMES = {
  "detected" => "検出",
  "not_detected" => "未検出",
  "out_of_scope" => "対象外",
  "execution_error" => "実行エラー"
}.freeze
ASSURANCE = {
  "proof" => "証明済み",
  "conditional_proof" => "前提付きの証明",
  "finite_model_check" => "有限モデル検査",
  "bounded_execution" => "同期点の範囲での実行網羅",
  "execution_check" => "実行照合",
  "unchecked" => "未検証"
}.freeze
ROLES = {
  "normal" => "正常系",
  "positive_control" => "陽性対照",
  "experiment_check" => "実験自体の確認",
  "comparison" => "方式の比較"
}.freeze
MEASUREMENTS = %w[trials trial_budget duration_ms time_budget_ms replay_steps].freeze
MARKDOWN_FORMATTING = Regexp.union("\\", "`", "*", "_", "[", "]", "~")

def read_report(path)
  report = JSON.parse(File.read(path))
  raise ArgumentError, "report must be an object" unless report.is_a?(Hash)
  raise ArgumentError, "version must be 1" unless report.fetch("version") == 1

  source = report.fetch("source")
  raise ArgumentError, "source must be a nonempty string" unless source.is_a?(String) && !source.empty?

  rows = report.fetch("rows")
  raise ArgumentError, "rows must be a nonempty array" unless rows.is_a?(Array) && !rows.empty?

  rows.map do |row|
    raise ArgumentError, "each row must be an object" unless row.is_a?(Hash)

    role = row.fetch("role")
    ROLES.fetch(role)
    observed = row.fetch("observed")
    OUTCOMES.fetch(observed)
    expected = row.fetch("expected")
    OUTCOMES.fetch(expected) unless expected.nil?
    if role != "comparison" && !%w[detected not_detected].include?(expected)
      raise ArgumentError, "a control must expect detected or not_detected"
    end

    level = row.fetch("assurance")
    ASSURANCE.fetch(level)
    if %w[out_of_scope execution_error].include?(observed) && level != "unchecked"
      raise ArgumentError, "an out-of-scope or failed result must use unchecked"
    end

    %w[property method case target assumptions scope checker].each do |key|
      value = row.fetch(key)
      raise ArgumentError, "#{key} must be a string" unless value.is_a?(String)
    end
    raise ArgumentError, "evidence must be an object" unless row.fetch("evidence").is_a?(Hash)

    MEASUREMENTS.each do |key|
      value = row.fetch(key)
      unless value.nil? || (value.is_a?(Integer) && value >= 0)
        raise ArgumentError, "#{key} must be a nonnegative integer or null"
      end
    end

    row.merge("source" => source)
  end
rescue ArgumentError, KeyError, TypeError, JSON::ParserError, SystemCallError => error
  abort "#{path}: #{error.message}"
end

def table_row(values)
  cells = values.map do |value|
    value.to_s.gsub(/[\r\n]+/, " ").gsub("&", "&amp;").gsub("<", "&lt;")
      .gsub(">", "&gt;").gsub("|", "&#124;").gsub(MARKDOWN_FORMATTING) { |character| "\\#{character}" }
  end
  puts "| #{cells.join(' | ')} |"
end

def row_status(row)
  return "実験エラー" if row.fetch("observed") == "execution_error"
  return "—" if row.fetch("role") == "comparison"

  row.fetch("observed") == row.fetch("expected") ? "合格" : "不合格"
end

abort "Usage: ruby reporting/summary.rb RESULTS.json [RESULTS.json ...]" if ARGV.empty?
rows = ARGV.flat_map { |path| read_report(path) }
identities = rows.map { |row| row.values_at("source", "property", "method", "case", "role") }
abort "Duplicate result rows" unless identities.uniq.size == rows.size

puts "## 性質ごとの保証段階"
puts
headers = %w[性質 方式 ケース 用途 期待 実測 確認 保証 対象 前提 範囲 チェッカー 試行実績/上限 時間実績/上限(ms) 再生ステップ 出典]
table_row(headers)
table_row(headers.map { "---" })
rows.each do |row|
  table_row([
    *row.values_at("property", "method", "case"),
    ROLES.fetch(row.fetch("role")), OUTCOMES.fetch(row.fetch("expected"), "—"),
    OUTCOMES.fetch(row.fetch("observed")), row_status(row),
    ASSURANCE.fetch(row.fetch("assurance")), *row.values_at("target", "assumptions", "scope", "checker"),
    row.values_at("trials", "trial_budget").map { |value| value || "—" }.join("/"),
    row.values_at("duration_ms", "time_budget_ms").map { |value| value || "—" }.join("/"),
    row.fetch("replay_steps") || "—", row.fetch("source")
  ])
end

exit 1 if rows.any? { |row| %w[実験エラー 不合格].include?(row_status(row)) }
