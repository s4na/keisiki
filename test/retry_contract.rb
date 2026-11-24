require "json"

module RetryContract
  REQUEST = { "reservation_id" => "reservation-1", "quantity" => 1 }.freeze
  INITIAL_QUANTITY = 2
  EXPECTED_RESERVATIONS = [{ "id" => "reservation-1", "stock_id" => 1, "quantity" => 1 }].freeze
  STOCK_AFTER_ONE_RESERVATION = 1

  class IncompleteHistory < StandardError; end

  def self.check(history)
    raise IncompleteHistory, "Expected a history object" unless history.is_a?(Hash)

    events = history.fetch("events")
    unless events.is_a?(Array) && events.all? { |entry| entry.is_a?(Hash) }
      raise IncompleteHistory, "Expected a list of history events"
    end

    initial = event(events, "db_snapshot", "before")
    first_request = event(events, "http_request", "initial")
    first_commit = event(events, "db_commit", "initial")
    first_db = event(events, "db_snapshot", "initial")
    withheld = event(events, "http_response_withheld", "initial")
    lost = event(events, "http_response_lost", "initial")
    second_request = event(events, "http_request", "retry")
    second_db = event(events, "db_snapshot", "retry")
    received = event(events, "http_response", "retry")

    ordered = [initial, first_request, first_commit, first_db, withheld, lost,
      second_request, second_db, received]
    positions = ordered.map { |entry| events.index(entry) }
    unless positions.each_cons(2).all? { |left, right| left < right } &&
        first_request.fetch("body") == REQUEST && second_request.fetch("body") == REQUEST &&
        first_commit.fetch("backend_pid") != first_db.fetch("backend_pid") &&
        lost.fetch("error") == "EOFError" && initial.fetch("stock") == INITIAL_QUANTITY &&
        initial.fetch("reservations").empty?
      raise IncompleteHistory, "Expected the declared initial state and one retry after a committed, lost response"
    end

    violations = []
    violations << "initial_receipt" unless [withheld.fetch("status"), withheld.fetch("body")] == [201, REQUEST]
    violations << "initial_reservation" unless first_db.fetch("reservations") == EXPECTED_RESERVATIONS
    violations << "initial_stock_debit" unless first_db.fetch("stock") == STOCK_AFTER_ONE_RESERVATION
    violations << "retry_receipt" unless [received.fetch("status"), received.fetch("body")] == [201, REQUEST]
    violations << "retry_reservation" unless second_db.fetch("reservations") == EXPECTED_RESERVATIONS
    violations << "retry_stock_unchanged" unless second_db.fetch("stock") == STOCK_AFTER_ONE_RESERVATION

    {
      status: violations.empty? ? "MATCH" : "CONTRACT_VIOLATION",
      violations: violations,
      expected: { initial_stock: INITIAL_QUANTITY, stock_after_reservation: STOCK_AFTER_ONE_RESERVATION,
        reservations: EXPECTED_RESERVATIONS, receipt: { status: 201, body: REQUEST } },
      observed: { stock_after_first_commit: first_db.fetch("stock"), stock_after_retry: second_db.fetch("stock"),
        reservations_after_retry: second_db.fetch("reservations") }
    }
  end

  def self.event(events, type, attempt)
    matches = events.select { |entry| entry["type"] == type && entry["attempt"] == attempt }
    raise IncompleteHistory, "Expected one #{type} event for #{attempt}, got #{matches.length}" unless matches.one?

    matches.first
  end

  private_class_method :event
end

if $PROGRAM_NAME == __FILE__
  begin
    result = RetryContract.check(JSON.parse(File.read(ARGV.fetch(0))))
    puts JSON.pretty_generate(result)
    exit(result.fetch(:violations).empty? ? 0 : 1)
  rescue RetryContract::IncompleteHistory, KeyError, IndexError, JSON::ParserError, Errno::ENOENT => error
    puts JSON.pretty_generate(status: "INCONCLUSIVE", reason: error.message)
    exit 2
  end
end
