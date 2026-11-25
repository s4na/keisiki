require "json"

def valid_case?(trial)
  initial_stock = trial.fetch("initial_stock")
  return false unless initial_stock.is_a?(Integer) && initial_stock.positive?

  first, *retries = trial.fetch("attempts")
  return false if first.nil? || retries.empty?

  request = first.fetch("request")
  id = request.fetch("reservation_id")
  quantity = request.fetch("quantity")
  id.match?(/\A[a-zA-Z0-9_-]{1,80}\z/) &&
    quantity.is_a?(Integer) && quantity.between?(1, initial_stock) &&
    %w[receive drop_after_commit].include?(first.fetch("response_mode")) &&
    retries.all? { |retry_attempt| retry_attempt == { "request" => request, "response_mode" => "receive" } }
end

seed, count, first_path, changed_path = ARGV
plans = JSON.parse(File.read(first_path))
changed_plans = JSON.parse(File.read(changed_path))
cases = plans.fetch("cases")
abort "unexpected plan metadata or trial count" unless plans.values_at("schema_version", "seed", "trial_count") ==
  [1, Integer(seed, 10), Integer(count, 10)] && cases.size == Integer(count, 10)
abort "a different seed did not change the generated operations" if cases == changed_plans.fetch("cases")

reference = plans.fetch("reference_case")
body = { "reservation_id" => "reservation-1", "quantity" => 1 }
expected_reference = {
  "initial_stock" => 2,
  "attempts" => [
    { "request" => body, "response_mode" => "drop_after_commit" },
    { "request" => body, "response_mode" => "receive" }
  ]
}
abort "common reference case changed" unless reference == expected_reference
abort "generated an invalid operation sequence" unless cases.all? { |trial| valid_case?(trial) }

invalid = Marshal.load(Marshal.dump(reference))
invalid.fetch("attempts").last.fetch("request")["reservation_id"] = "different"
abort "accepted a retry with a changed reservation ID" if valid_case?(invalid)
invalid = Marshal.load(Marshal.dump(reference))
invalid.fetch("attempts").reverse!
abort "accepted response loss on a retry" if valid_case?(invalid)

dropped = cases.count { |trial| trial.fetch("attempts").first.fetch("response_mode") == "drop_after_commit" }
retry_counts = cases.map { |trial| trial.fetch("attempts").length - 1 }.uniq.sort
abort "expected both initial response modes and all retry counts" unless dropped.between?(1, cases.size - 1) &&
  retry_counts == [1, 2, 3]

puts JSON.pretty_generate(
  seed: plans.fetch("seed"), trial_count: cases.size,
  initial_response_received: cases.size - dropped,
  initial_response_loss_requested: dropped, retry_counts: retry_counts
)
