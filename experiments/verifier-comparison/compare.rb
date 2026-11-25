require "digest"
require "fileutils"
require "json"
require "open3"

def replace_once(source, before, after)
  raise "Expected one source location for #{before.inspect}" unless source.scan(before).one?

  source.sub(before, after)
end

def outcome(exit_code, stdout, stderr)
  return "verified" if exit_code == 0
  return "rejected" if exit_code == 1
  return "execution_error" unless exit_code == 2

  # The generation CLI writes a JSON verdict. The comparison CLI writes a labeled diagnostic.
  if stderr.lines.any? { |line| line.start_with?("UNSUPPORTED ") }
    return "unsupported"
  end

  report = JSON.parse(stdout)
  report.is_a?(Hash) && report["status"] == "unsupported" ? "unsupported" : "execution_error"
rescue JSON::ParserError
  "execution_error"
end

abort "Usage: ruby compare.rb CHECKER_WORKTREE ARTIFACT_DIRECTORY" unless ARGV.size == 2

candidate, artifacts = ARGV.map { |path| File.expand_path(path) }
source = File.binread(File.join(__dir__, "reserve_stock.rb"))
mutations = [
  ["layout_only", "equivalent", "    reservation.nil?\n", "    # Check whether an existing row was read.\n    reservation.nil?\n"],
  ["condition_rewritten", "equivalent", "    reservation.nil?\n", "    if reservation.nil? then true else false end\n"],
  ["debit_inverted", "p1_violation", "    reservation.nil?\n", "    !reservation.nil?\n"],
  ["debit_always", "p1_violation", "    reservation.nil?\n", "    reservation.nil? || !reservation.nil?\n"],
  ["amount_subtracted", "p1_violation", "stock.quantity - quantity", "stock.quantity - (quantity + 1)"],
  ["persisted_quantity", "p1_violation", "stock_id: stock.id, quantity: quantity", "stock_id: stock.id, quantity: quantity + 1"],
  ["transaction_removed", "outside_runtime_contract", "    Stock.transaction do\n", "    begin\n"],
  ["dynamic_dispatch", "outside_static_subset", "    reservation.nil?\n", "    reservation.public_send(:nil?)\n"]
]
cases = [["original", "reference", source]]
mutations.each { |name, oracle, before, after| cases << [name, oracle, replace_once(source, before, after)] }

FileUtils.mkdir_p(artifacts)
revision, git_status = Open3.capture2("git", "rev-parse", "HEAD", chdir: candidate)
abort "Cannot identify the verifier revision" unless git_status.success?
verifier = File.join(candidate, "bin", "check-reserve-stock")
abort "Missing executable: #{verifier}" unless File.executable?(verifier)

outcomes = cases.map do |name, oracle, input|
  path = File.join(artifacts, "#{name}.rb")
  File.binwrite(path, input)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stdout, stderr, status = Open3.capture3("timeout", "--kill-after=5s", "60s", verifier, path, chdir: candidate)
  elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1_000).round

  File.write(File.join(artifacts, "#{name}.stdout"), stdout)
  File.write(File.join(artifacts, "#{name}.stderr"), stderr)
  { case: name, oracle: oracle, result: outcome(status.exitstatus, stdout, stderr),
    exit_code: status.exitstatus, elapsed_ms: elapsed_ms }
end

report = {
  head: revision.strip,
  source_sha256: Digest::SHA256.hexdigest(source),
  scope: "ReserveStock isolated retry; #{cases.size} source variants",
  outcomes: outcomes
}
puts JSON.pretty_generate(report)
if outcomes.first.fetch(:result) != "verified" || outcomes.any? { |entry| entry.fetch(:result) == "execution_error" }
  warn "The comparison did not complete with a verified original and interpretable conclusions"
  exit 1
end
