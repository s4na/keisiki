require "json"
require_relative "retry_contract"

UPDATE = 'UPDATE "stocks" SET "quantity" = $1 WHERE "stocks"."id" = $2'
INSERT = 'INSERT INTO "reservations" ("id", "stock_id", "quantity") VALUES ($1, $2, $3) RETURNING "id"'
ACTIONS = %w[Commit LoseResponse Retry].freeze
PHASES = %w[ready committed response_lost retried].freeze

class EvidenceMismatch < StandardError; end

def fetch_event(events, type, attempt)
  found = events.select { |event| event.values_at("type", "attempt") == [type, attempt] }
  raise EvidenceMismatch, "Expected exactly one #{type}/#{attempt}" unless found.one?

  found.first
end

def db_frame(snapshot, phase, first_result, retry_result)
  {
    "phase" => phase,
    "stock" => snapshot.fetch("stock"),
    "reservations" => snapshot.fetch("reservations").map do |row|
      raise EvidenceMismatch, "Reservation belongs to a different stock" unless row.fetch("stock_id") == 1

      { "reservation_id" => row.fetch("id"), "quantity" => row.fetch("quantity") }
    end,
    "firstResult" => first_result,
    "retryResult" => retry_result
  }
end

def require_write_trace(events, attempt, snapshot, writes)
  request = fetch_event(events, "http_request", attempt)
  commit = fetch_event(events, "db_commit", attempt)
  sql = events.select { |event| event.values_at("type", "attempt") == ["sql", attempt] }
  positions = [request, *sql, commit, snapshot].map { |event| events.index(event) }
  unless positions.each_cons(2).all? { |left, right| left < right }
    raise EvidenceMismatch, "#{attempt}: SQL is outside the observed transaction"
  end

  app_pid = commit.fetch("backend_pid")
  unless app_pid != snapshot.fetch("backend_pid") &&
      sql.all? { |event| event.fetch("backend_pid") == app_pid && event.fetch("succeeded") == true }
    raise EvidenceMismatch, "#{attempt}: missing successful writes on the committing connection"
  end

  statements = sql.map { |event| event.values_at("statement", "binds", "affected_rows") }
  expected = [["BEGIN", [], 0], *writes, ["COMMIT", [], 0]]
  raise EvidenceMismatch, "#{attempt}: unexpected SQL, bind values, or row counts" unless statements == expected
end

def rails_trace(history, variant)
  raise EvidenceMismatch, "Expected history for #{variant}" unless history.fetch("variant") == variant

  verdict = RetryContract.check(history)
  expected_violations = variant == "baseline" ? [] : ["retry_stock_unchanged"]
  unless verdict.fetch(:violations) == expected_violations
    raise EvidenceMismatch, "#{variant}: unexpected contract verdict #{verdict.fetch(:violations).inspect}"
  end

  events = history.fetch("events")
  before, first_db, after_loss, retry_db =
    %w[before initial after_loss retry].map { |attempt| fetch_event(events, "db_snapshot", attempt) }
  lost = fetch_event(events, "http_response_lost", "initial")
  retry_request = fetch_event(events, "http_request", "retry")
  unless events.index(lost) < events.index(after_loss) && events.index(after_loss) < events.index(retry_request)
    raise EvidenceMismatch, "Expected a post-loss observation before the retry"
  end

  request = fetch_event(events, "http_request", "initial").fetch("body")
  receipt = fetch_event(events, "http_response_withheld", "initial").fetch("body")
  retry_receipt = fetch_event(events, "http_response", "retry").fetch("body")
  first_writes = [
    [UPDATE, [first_db.fetch("stock"), 1], 1],
    [INSERT, [request.fetch("reservation_id"), 1, request.fetch("quantity")], 1]
  ]
  require_write_trace(events, "initial", first_db, first_writes)
  retry_writes = variant == "baseline" ? [] : [[UPDATE, [retry_db.fetch("stock"), 1], 1]]
  require_write_trace(events, "retry", retry_db, retry_writes)

  [
    db_frame(before, "ready", nil, nil),
    db_frame(first_db, "committed", receipt, nil),
    db_frame(after_loss, "response_lost", receipt, nil),
    db_frame(retry_db, "retried", receipt, retry_receipt)
  ]
end

def tlc_trace(counterexample)
  witness = counterexample.fetch("counterexample")
  actions = witness.fetch("action").map { |_index, action| action.fetch("name") }
  raise EvidenceMismatch, "TLC reports unexpected actions #{actions.inspect}" unless actions == ACTIONS

  witness.fetch("state").map do |_index, state|
    %w[firstResult retryResult].each do |name|
      state[name] = nil if state.fetch(name) == { "reservation_id" => "", "quantity" => 0 }
    end
    state
  end
end

def read_json(path)
  JSON.parse(File.read(path))
end

abort "Usage: ruby test/retry_conformance.rb RAILS_ARTIFACTS TLC_ARTIFACTS LEAN.json" unless ARGV.size == 3

begin
  rails_dir, tlc_dir, lean_path = ARGV
  lean = read_json(lean_path)
  rails = %w[baseline double_update].to_h do |variant|
    actual = rails_trace(read_json(File.join(rails_dir, "#{variant}.json")), variant)
    expected = lean.fetch(variant)
    unless actual == expected
      raise EvidenceMismatch, "#{variant}: Rails and Lean traces differ\n#{JSON.pretty_generate(rails: actual, lean: expected)}"
    end
    [variant, actual]
  end

  tlc = read_json(File.join(tlc_dir, "result.json"))
  unless tlc.dig("normal", "observed") == "no_violation" &&
      tlc.dig("double_update", "observed") == "invariant_violation"
    raise EvidenceMismatch, "TLC normal/positive control outcomes differ from the experiment conditions"
  end
  counterexample = tlc_trace(read_json(File.join(tlc_dir, "counterexample.json")))
  raise EvidenceMismatch, "TLC and Rails counterexample traces differ" unless counterexample == rails.fetch("double_update")

  puts JSON.pretty_generate(
    property: "P1",
    scope: { phase_count: PHASES.size, initial_stock: RetryContract::INITIAL_QUANTITY, retry_count: 1 },
    baseline: { rails_lean_match: true, tlc_reachable_states: tlc.fetch("normal").fetch("states_checked"),
      stocks: rails.fetch("baseline").map { |state| state.fetch("stock") } },
    double_update: { rails_lean_tlc_match: true, actions: ACTIONS,
      stocks: counterexample.map { |state| state.fetch("stock") } }
  )
rescue EvidenceMismatch, RetryContract::IncompleteHistory, KeyError, TypeError, JSON::ParserError, SystemCallError => error
  warn error.message
  exit 1
end
