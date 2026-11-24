require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../lib/postgres_update_to_lean"
require_relative "postgres_runtime"

ROOT = File.expand_path("..", __dir__)
EXAMPLE = File.join(ROOT, "examples/postgres")
SAFE_SQL = File.binread(File.join(EXAMPLE, "reserve.sql"))

def lean(directory, *arguments)
  path = [directory, File.join(ROOT, ".lake/build/lib/lean")].join(File::PATH_SEPARATOR)
  Open3.capture2e({ "LEAN_PATH" => path }, "lean", "-DwarningAsError=true", *arguments, chdir: directory)
end

def expect_lean(directory, *arguments, success: true)
  output, status = lean(directory, *arguments)
  unless status.success? == success
    abort "Unexpected Lean result for #{arguments.last} (exit #{status.exitstatus}):\n#{output}"
  end

  output
end

def compile_sql(parent, name, sql)
  directory = File.join(parent, name)
  Dir.mkdir(directory)
  FileUtils.cp(File.join(ROOT, "lean-toolchain"), directory)
  File.binwrite(File.join(directory, "query.sql"), sql)
  File.write(File.join(directory, "GeneratedSQL.lean"), PostgresUpdateToLean.generate(sql))
  expect_lean(directory, "-o", "GeneratedSQL.olean", "GeneratedSQL.lean")
  directory
end

def proof(directory, name, success: true)
  FileUtils.cp(File.join(EXAMPLE, "#{name}.lean"), File.join(directory, "Audit.lean"))
  expect_lean(directory, "-o", "Audit.olean", "Audit.lean", success: success)
  return unless success

  JSON.parse(expect_lean(directory, "--run", File.join(ROOT, "script/audit.lean"), "--postgres"))
end

def model_checks(scenario)
  initial = scenario.fetch(:initial)
  stock = initial
  transactions = scenario.fetch(:transactions)
  checks = transactions.map do |amount, ending, returned|
    expected = returned.nil? ? "none" : "some (#{returned})"
    equality = "example : GeneratedSQL.update.returning (#{stock}) (#{amount}) = #{expected} := by rfl"
    stock = returned if ending == :commit && !returned.nil?
    equality
  end
  history = transactions.map { |amount, ending, _| "⟨(#{amount}), .#{ending}⟩" }.join(", ")
  state = "run GeneratedSQL.update ⟨(#{initial}), 0⟩ [#{history}]"
  checks << "example : (#{state}).remaining = (#{scenario.fetch(:remaining)}) := by rfl"
  checks << "example : (#{state}).reserved = (#{scenario.fetch(:reserved)}) := by rfl"
end

def match_actual(directory, scenarios)
  program = "import GeneratedSQL\nopen Keisiki.Postgres\n"
  checks = scenarios.values.flat_map { |scenario| model_checks(scenario) }
  File.write(File.join(directory, "Conformance.lean"), program + checks.join("\n") + "\n")
  expect_lean(directory, "Conformance.lean")
  scenarios.each { |name, scenario| puts "PostgreSQL/Lean #{name}: #{scenario.inspect}" }
end

def publish(name, directory, scenarios, status, axioms)
  root = ENV["KEISIKI_POSTGRES_ARTIFACT_DIR"]
  return unless root

  target = File.join(root, name)
  FileUtils.mkdir_p(target)
  FileUtils.cp(%w[query.sql GeneratedSQL.lean Audit.lean Conformance.lean].map { |file| File.join(directory, file) }, target)
  report = { status: status, axioms: axioms, sql_sha256: Digest::SHA256.file(File.join(directory, "query.sql")).hexdigest, replays: scenarios }
  File.write(File.join(target, "result.json"), JSON.pretty_generate(report))
end

def validate(scenario, returns, remaining, reserved, blocked: false)
  actual_returns = scenario.fetch(:transactions).map(&:last)
  unless actual_returns == returns && scenario.fetch(:remaining) == remaining &&
      scenario.fetch(:reserved) == reserved && scenario.fetch(:blocked, false) == blocked
    abort "Unexpected PostgreSQL replay: #{scenario.inspect}"
  end
end

url = ENV.fetch("KEISIKI_POSTGRES_TEST_URL")
output, built = Open3.capture2e("lake", "build", chdir: ROOT)
abort output unless built.success?

Dir.mktmpdir("keisiki-postgres-") do |parent|
  baseline = compile_sql(parent, "baseline", SAFE_SQL)
  axioms = proof(baseline, "NoOversell")
  puts "PROVEN_CONDITIONAL: every modeled committed history preserves nonnegative stock and never oversells"

  overdraw_sql = SAFE_SQL.sub("  AND quantity >= $1::bigint\n", "")
  negative_sql = SAFE_SQL.sub("  AND $1::bigint > 0\n", "")
  abort "A mutation did not change the SQL" if [overdraw_sql, negative_sql].include?(SAFE_SQL)

  oversell = compile_sql(parent, "oversell", overdraw_sql)
  proof(oversell, "NoOversell", success: false)
  oversell_axioms = proof(oversell, "Oversell")
  negative = compile_sql(parent, "negative", negative_sql)
  proof(negative, "NoOversell", success: false)
  negative_axioms = proof(negative, "NegativeRequest")

  PostgresRuntime.with_database(url) do |database|
    puts "PostgreSQL server_version_num: #{database.version}"
    max_bigint = 2**63 - 1
    cases = {
      waiting_after_commit: database.overlapping(SAFE_SQL, first_finish: :commit),
      waiting_after_rollback: database.overlapping(SAFE_SQL, first_finish: :rollback),
      negative_request: database.single(SAFE_SQL, 0, -1),
      zero_request: database.single(SAFE_SQL, 0, 0),
      bigint_boundary: database.single(SAFE_SQL, max_bigint, max_bigint)
    }
    validate(cases.fetch(:waiting_after_commit), [0, nil], 0, 1, blocked: true)
    validate(cases.fetch(:waiting_after_rollback), [0, 0], 0, 1, blocked: true)
    validate(cases.fetch(:negative_request), [nil], 0, 0)
    validate(cases.fetch(:zero_request), [nil], 0, 0)
    validate(cases.fetch(:bigint_boundary), [0], 0, max_bigint)
    match_actual(baseline, cases)
    publish("baseline", baseline, cases, "PROVEN_CONDITIONAL", axioms)

    overdraw = database.overlapping(overdraw_sql, first_finish: :commit)
    validate(overdraw, [0, -1], -1, 2, blocked: true)
    match_actual(oversell, { missing_stock_guard: overdraw })
    publish("oversell", oversell, { missing_stock_guard: overdraw }, "COUNTEREXAMPLE", oversell_axioms)

    negative_request = database.single(negative_sql, 0, -1)
    validate(negative_request, [1], 1, -1)
    match_actual(negative, { missing_positive_guard: negative_request })
    publish("negative", negative, { missing_positive_guard: negative_request }, "COUNTEREXAMPLE", negative_axioms)
  end

  unsupported = {
    "predicate selecting multiple rows" => SAFE_SQL.sub("id = 1", "(id = 1 OR id = 2)"),
    "assignment to the row key" => SAFE_SQL.gsub("quantity", "id")
  }
  unsupported.each do |name, sql|
    begin
      PostgresUpdateToLean.generate(sql)
      abort "Expected unsupported SQL: #{name}"
    rescue PostgresUpdateToLean::Unsupported
      puts "UNSUPPORTED: #{name}"
    end
  end
end
