require "json"
require "pg"
require "securerandom"

class PostgresReplay
  INITIAL_STOCK = 1
  STOCK_READ = "SELECT quantity FROM stocks WHERE id = 1"

  def initialize(variant)
    @variant = variant
    @schema = "dst_#{SecureRandom.hex(8)}"
    @sessions = []
    @steps = []
  end

  def run
    started_at = monotonic_time
    raise ArgumentError, "variant must be baseline or stale_read" unless %w[baseline stale_read].include?(@variant)

    run_database
  rescue StandardError => error
    { status: "execution_error", error_class: error.class.name, error: error.message }
  ensure
    @duration_ms = ((monotonic_time - started_at) * 1000).round(1)
  end

  def evidence(result)
    {
      property: "P3",
      method: "postgres_schedule_replay",
      variant: @variant,
      initial_stock: INITIAL_STOCK,
      requests: [{ id: "A", quantity: 1 }, { id: "B", quantity: 1 }],
      postgres_version: @postgres_version,
      steps: @steps,
      duration_ms: @duration_ms,
      **result
    }
  end

  private

  def run_database
    @observer = connect
    prepare_database
    replay(connect, connect)

    stock = Integer(@observer.exec(STOCK_READ).getvalue(0, 0))
    reservations = @observer.exec("SELECT id FROM reservations ORDER BY id").column_values(0)
    violations = []
    violations << "at_most_one_committed_reservation" if reservations.length > INITIAL_STOCK
    violations << "stock_is_nonnegative" if stock.negative?
    {
      status: violations.empty? ? "passed" : "contract_violation",
      stock: stock,
      committed_reservations: reservations,
      violations: violations
    }
  ensure
    cleanup
  end

  def connect
    session = PG.connect(ENV.fetch("KEISIKI_DST_DATABASE_URL"))
    @sessions << session
    session.exec("SET statement_timeout = '10s'")
    session.exec("SET search_path TO #{@schema}, pg_catalog")
    session
  end

  def prepare_database
    @postgres_version = @observer.exec("SHOW server_version").getvalue(0, 0)
    @observer.exec("CREATE SCHEMA #{@schema}")
    @schema_created = true
    @observer.exec(<<~SQL)
      CREATE TABLE stocks (
        id bigint PRIMARY KEY,
        quantity bigint NOT NULL CHECK (quantity >= 0)
      );
      CREATE TABLE reservations (
        id varchar(80) PRIMARY KEY,
        stock_id bigint NOT NULL REFERENCES stocks (id),
        quantity bigint NOT NULL CHECK (quantity > 0)
      );
      INSERT INTO stocks VALUES (1, #{INITIAL_STOCK});
    SQL
  end

  def replay(first, second)
    first.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
    first_stock = Integer(first.exec("#{STOCK_READ} FOR UPDATE").getvalue(0, 0))
    @steps << { request: "A", event: "stock_read_for_update", stock: first_stock }

    second.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
    second.send_query(@variant == "baseline" ? "#{STOCK_READ} FOR UPDATE" : STOCK_READ)
    @steps << { request: "B", event: "stock_read_dispatched" }
    observe_second_query(first, second)

    reserve_or_reject(first, "A", first_stock)
    second_stock = Integer(second.get_last_result.getvalue(0, 0))
    @steps << { request: "B", event: "stock_read_taken", stock: second_stock }
    reserve_or_reject(second, "B", second_stock)
  end

  def observe_second_query(first, second)
    deadline = monotonic_time + 5
    loop do
      second.consume_input
      unless second.is_busy
        @steps << { request: "B", event: "stock_read_completed_before_a_commit" }
        return
      end

      blocked = @observer.exec_params(
        "SELECT $1::integer = ANY(pg_blocking_pids($2::integer))",
        [first.backend_pid, second.backend_pid]
      ).getvalue(0, 0) == "t"
      if blocked
        @steps << { request: "B", event: "blocked_by_a_before_a_commit" }
        return
      end

      raise "B neither completed its read nor was observed waiting on A" if monotonic_time >= deadline

      sleep 0.01
    end
  end

  def reserve_or_reject(session, request, stock)
    if stock < 1
      session.exec("ROLLBACK")
      @steps << { request: request, event: "rolled_back_insufficient_stock" }
      return
    end

    session.exec_params("UPDATE stocks SET quantity = $1 WHERE id = 1", [stock - 1])
    session.exec_params("INSERT INTO reservations VALUES ($1, 1, 1)", [request])
    session.exec("COMMIT")
    @steps << { request: request, event: "committed" }
  end

  def cleanup
    @sessions.reverse_each { |session| session.finish unless session.equal?(@observer) }
    return unless @observer

    @observer.exec("DROP SCHEMA #{@schema} CASCADE") if @schema_created
  ensure
    @observer&.finish
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

ENV["PGCONNECT_TIMEOUT"] ||= "5"
replay = PostgresReplay.new(ARGV.fetch(0, "baseline"))
result = replay.run
puts JSON.pretty_generate(replay.evidence(result))
exit({ "passed" => 0, "contract_violation" => 1, "execution_error" => 2 }.fetch(result.fetch(:status)))
