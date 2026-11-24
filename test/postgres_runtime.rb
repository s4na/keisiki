require "pg"
require "securerandom"
require_relative "../examples/postgres/reservation"

class PostgresRuntime
  SCHEMA_SQL = File.expand_path("../examples/postgres/schema.sql", __dir__)
  TRANSACTION_END = { commit: "COMMIT", rollback: "ROLLBACK" }.freeze

  def self.with_database(url, schema_sql: File.binread(SCHEMA_SQL))
    database = new(url, schema_sql)
    yield database
  ensure
    database&.close
  end

  def initialize(url, schema_sql)
    @url = url
    @monitor = PG.connect(url)
    name = @monitor.quote_ident("keisiki_test_#{SecureRandom.hex(8)}")
    @monitor.exec("CREATE SCHEMA #{name}")
    @schema = name
    configure(@monitor)
    @monitor.exec(schema_sql)
    @version = @monitor.server_version
    raise "This replay requires PostgreSQL 18" unless @version / 10_000 == 18
  rescue
    close
    raise
  end

  attr_reader :version

  def single(sql, initial, amount, reservation: Reservation)
    reset(initial)
    returned = reservation.new(@monitor, sql: sql).reserve(amount)
    finish(initial, [[amount, :commit, returned]])
  end

  def overlapping(sql, first_finish:, transaction_end: TRANSACTION_END)
    reset(1)
    first = connect
    second = connect
    first.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
    first_return = Reservation.new(first, sql: sql).reserve(1)
    first_pid = first.backend_pid
    second_pid = second.backend_pid

    worker = Thread.new do
      second.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
      result = Reservation.new(second, sql: sql).reserve(1)
      second.exec("COMMIT")
      result
    end
    wait_until_blocked(first_pid, second_pid, worker)
    first_command = first.exec(transaction_end.fetch(first_finish)) { |result| result.cmd_status }
    raise "Second transaction did not finish" unless worker.join(10)

    # The caller accounts for its intended outcome. Keep PostgreSQL's actual command tag alongside it.
    finish(1, [[1, first_finish, first_return], [1, :commit, worker.value]]).merge(blocked: true, first_command: first_command)
  ensure
    first&.close
    begin
      worker&.join(13)
    ensure
      second&.close
    end
  end

  def duplicate_stock_key
    reset(1)
    begin
      @monitor.exec("INSERT INTO keisiki_stock VALUES (1, 2)")
    rescue PG::UniqueViolation => error
      sqlstate = error.result.error_field(PG::PG_DIAG_SQLSTATE)
    end
    quantities = @monitor.exec("SELECT quantity FROM keisiki_stock WHERE id = 1 ORDER BY quantity")
    { sqlstate: sqlstate, quantities: quantities.values.flatten.map { |value| Integer(value, 10) } }
  end

  def close
    return unless @monitor && !@monitor.finished?

    begin
      @monitor.exec("DROP SCHEMA #{@schema} CASCADE") if @schema
    ensure
      @monitor.close
    end
  end

  private

  def connect
    connection = PG.connect(@url)
    configure(connection)
    connection
  rescue
    connection&.close
    raise
  end

  def configure(connection)
    connection.exec("SET search_path TO #{@schema}, pg_catalog")
    connection.exec("SET statement_timeout TO '12s'")
    connection.exec("SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL READ COMMITTED")
  end

  def reset(initial)
    @monitor.exec("TRUNCATE keisiki_stock")
    @monitor.exec_params("INSERT INTO keisiki_stock VALUES (1, $1), (2, 77)", [initial])
  end

  def finish(initial, transactions)
    rows = @monitor.exec("SELECT id, quantity FROM keisiki_stock ORDER BY id").values.map do |row|
      row.map { |value| Integer(value, 10) }
    end
    raise "Reservation changed a different row" unless rows.map(&:first) == [1, 2] && rows.last.last == 77

    reserved = transactions.sum { |amount, ending, returned| ending == :commit && returned ? amount : 0 }
    { initial: initial, transactions: transactions, remaining: rows.first.last, reserved: reserved }
  end

  def wait_until_blocked(first_pid, second_pid, worker)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      waiting = @monitor.exec_params("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [first_pid, second_pid])
      return if waiting.getvalue(0, 0) == "t"

      unless worker.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        raise "PostgreSQL did not report the second UPDATE waiting for the first transaction"
      end
      sleep 0.02
    end
  end
end
