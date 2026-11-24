require "fileutils"
require "json"
require "net/http"
require "pg"
require "puma"
require "securerandom"
require_relative "retry_contract"

class RetryRun
  HOST = "127.0.0.1"
  PATH = "/stock/reservations"
  SCHEMA_SQL = File.expand_path("../example/db/schema.sql", __dir__)

  def initialize(url, variant)
    @url = url
    @variant = variant
    @events = []
    @history_lock = Mutex.new
  end

  def run
    @observer = PG.connect(@url)
    schema = "keisiki_retry_#{SecureRandom.hex(8)}"
    @observer.exec("CREATE SCHEMA #{schema}")
    @schema = schema
    @observer.exec("SET search_path = #{@schema}, pg_catalog")
    @observer.exec(File.binread(SCHEMA_SQL))
    @observer.exec_params("INSERT INTO stocks (id, quantity) VALUES (1, $1)", [RetryContract::INITIAL_QUANTITY])

    ENV["RAILS_ENV"] = "test"
    ENV["KEISIKI_POSTGRES_TEST_SCHEMA"] = @schema
    require_relative "../example/config/application"
    Rails.application.initialize!
    @pool = ActiveRecord::Base.connection_pool

    if @variant == "double_update"
      require_relative "fixtures/double_update"
      ReserveStock.prepend(DoubleUpdate)
    end

    @server = Puma::Server.new(method(:serve))
    @server.add_tcp_listener(HOST, 0)
    @server.run
    @port = @server.connected_ports.fetch(0)

    observe_db("before")
    request("initial")
    request("retry")
    { variant: @variant, postgres_version: @observer.server_version, events: @events }
  ensure
    close
  end

  private

  def close
    @server&.stop(true)
    @pool&.disconnect!
  ensure
    if @observer
      begin
        @observer.exec("DROP SCHEMA #{@schema} CASCADE") if @schema
      ensure
        @observer.close
      end
    end
  end

  def serve(env)
    attempt = env.fetch("HTTP_X_KEISIKI_ATTEMPT")
    server_thread = Thread.current
    record_sql = lambda do |event|
      record_statement(event.payload, attempt) if Thread.current == server_thread
    end
    response = ActiveSupport::Notifications.subscribed(record_sql, "sql.active_record") do
      Rails.application.call(env)
    end
    observe_db(attempt)
    return response unless attempt == "initial"

    status, _headers, body = response
    content = +""
    body.each { |chunk| content << chunk }
    body.close if body.respond_to?(:close)
    record("http_response_withheld", attempt, status: status, body: JSON.parse(content))
    # The app already returned and a separate PostgreSQL session observed the committed state.
    env.fetch("rack.hijack").call.close
    [-1, {}, []]
  end

  def record_statement(payload, attempt)
    sql = payload.fetch(:sql)
    return unless sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|INSERT|UPDATE)\b/i)

    binds = payload.fetch(:type_casted_binds, nil)
    binds = binds.call if binds.respond_to?(:call)
    record("sql", attempt, statement: sql, binds: binds || [], affected_rows: payload[:affected_rows])
    if sql == "COMMIT" && !payload[:exception]
      record("db_commit", attempt, backend_pid: payload.fetch(:connection).raw_connection.backend_pid)
    end
  end

  def request(attempt)
    post = Net::HTTP::Post.new(PATH, "Content-Type" => "application/json", "X-Keisiki-Attempt" => attempt)
    post.body = JSON.generate(RetryContract::REQUEST)
    record("http_request", attempt, body: RetryContract::REQUEST)

    response = Net::HTTP.start(HOST, @port, nil, open_timeout: 5, read_timeout: 10, max_retries: 0) do |http|
      http.request(post)
    end
    record("http_response", attempt, status: response.code.to_i, body: JSON.parse(response.body))
  rescue EOFError => error
    raise unless attempt == "initial"

    record("http_response_lost", attempt, error: error.class.name)
  end

  def observe_db(attempt)
    row = @observer.exec(<<~SQL).first
      SELECT quantity, (
        SELECT COALESCE(jsonb_agg(to_jsonb(reservations) ORDER BY id), '[]'::jsonb) FROM reservations
      ) AS reservations
      FROM stocks WHERE id = 1
    SQL
    record("db_snapshot", attempt, stock: Integer(row.fetch("quantity"), 10),
      reservations: JSON.parse(row.fetch("reservations")), backend_pid: @observer.backend_pid)
  end

  def record(type, attempt, **attributes)
    @history_lock.synchronize { @events << { type: type, attempt: attempt, **attributes } }
  end
end

variant, output_path = ARGV
abort "Usage: #{$PROGRAM_NAME} baseline|double_update HISTORY.json" unless %w[baseline double_update].include?(variant) && output_path

history = RetryRun.new(ENV.fetch("KEISIKI_POSTGRES_TEST_URL"), variant).run
FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, JSON.pretty_generate(history) + "\n")
