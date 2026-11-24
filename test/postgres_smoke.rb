require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../lib/postgres_update_to_lean"
require_relative "postgres_runtime"

ROOT = File.expand_path("..", __dir__)
EXAMPLE = File.join(ROOT, "examples/postgres")
SAFE_SQL = File.binread(File.join(EXAMPLE, "reserve.sql"))

class OffByOneReservation < Reservation
  def reserve(quantity)
    super(quantity - 1)
  end
end

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

def compile_sql(parent, name, sql, generated: PostgresUpdateToLean.generate(sql))
  directory = File.join(parent, name)
  Dir.mkdir(directory)
  FileUtils.cp(File.join(ROOT, "lean-toolchain"), directory)
  File.binwrite(File.join(directory, "query.sql"), sql)
  File.write(File.join(directory, "GeneratedSQL.lean"), generated)
  expect_lean(directory, "-o", "GeneratedSQL.olean", "GeneratedSQL.lean")
  directory
end

def proof(directory, name, success: true)
  FileUtils.cp(File.join(EXAMPLE, "#{name}.lean"), File.join(directory, "Audit.lean"))
  expect_lean(directory, "-o", "Audit.olean", "Audit.lean", success: success)
  return unless success

  JSON.parse(expect_lean(directory, "--run", File.join(ROOT, "script/audit.lean"), "--postgres"))
end

def model_observations(scenario)
  initial = scenario.fetch(:initial)
  stock = initial
  transactions = scenario.fetch(:transactions)
  checks = transactions.map do |amount, ending, returned|
    expected = returned.nil? ? "none" : "some (#{returned})"
    equality = "GeneratedSQL.update.returning (#{stock}) (#{amount}) = #{expected}"
    stock = returned if ending == :commit && !returned.nil?
    equality
  end
  history = transactions.map { |amount, ending, _| "⟨(#{amount}), .#{ending}⟩" }.join(", ")
  state = "run GeneratedSQL.update ⟨(#{initial}), 0⟩ [#{history}]"
  checks << "(#{state}).remaining = (#{scenario.fetch(:remaining)})"
  checks << "(#{state}).reserved = (#{scenario.fetch(:reserved)})"
end

def match_actual(directory, scenarios)
  program = "import GeneratedSQL\nopen Keisiki.Postgres\n"
  checks = scenarios.values.flat_map do |scenario|
    model_observations(scenario).map { |equality| "example : #{equality} := by rfl" }
  end
  File.write(File.join(directory, "Conformance.lean"), program + checks.join("\n") + "\n")
  expect_lean(directory, "Conformance.lean")
  scenarios.each { |name, scenario| puts "PostgreSQL/Lean #{name}: #{scenario.inspect}" }
end

def prove_mismatch(directory, file, observed)
  checks = model_observations(observed).map { |equality| "(#{equality})" }.join(" ∧\n  ")
  program = "import GeneratedSQL\nopen Keisiki.Postgres\nexample : ¬ (#{checks}) := by decide\n"
  File.write(File.join(directory, file), program)
  expect_lean(directory, file)
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

def check_inventory(scenario, *expected)
  initial = scenario.fetch(:initial)
  remaining = scenario.fetch(:remaining)
  reserved = scenario.fetch(:reserved)
  violations = []
  violations << :negative_stock if remaining < 0
  violations << :negative_reserved if reserved < 0
  violations << :inventory_balance if remaining + reserved != initial
  violations << :oversell if reserved > initial
  abort "Expected inventory violations #{expected.inspect}, got #{violations.inspect}: #{scenario.inspect}" unless violations == expected

  violations
end

def publish_layer_checks(baseline, translation, results)
  results.each { |name, evidence| puts "#{name}: #{evidence.inspect}" }
  root = ENV["KEISIKI_POSTGRES_ARTIFACT_DIR"]
  return unless root

  target = File.join(root, "layer-mutations")
  FileUtils.mkdir_p(target)
  FileUtils.cp(Dir.glob(File.join(baseline, "*Mismatch.lean")), File.join(root, "baseline"))
  FileUtils.cp(%w[query.sql GeneratedSQL.lean TranslationMismatch.lean].map { |file| File.join(translation, file) }, target)
  File.write(File.join(target, "result.json"), JSON.pretty_generate(results))
end

def verify_layer_mutations(url, baseline, translation, cases, database)
  corrected_binding = cases.fetch(:exact_request)
  ruby_binding = database.single(SAFE_SQL, 2, 2, reservation: OffByOneReservation)
  validate(ruby_binding, [1], 1, 2)
  ruby_violations = check_inventory(ruby_binding, :inventory_balance)
  prove_mismatch(baseline, "RubyBindingMismatch.lean", ruby_binding)

  corrected_rollback = cases.fetch(:waiting_after_rollback)
  commits_on_rollback = PostgresRuntime::TRANSACTION_END.merge(rollback: "COMMIT")
  transaction_end = database.overlapping(SAFE_SQL, first_finish: :rollback, transaction_end: commits_on_rollback)
  validate(transaction_end, [0, nil], 0, 0, blocked: true)
  unless [corrected_rollback.fetch(:first_command), transaction_end.fetch(:first_command)] == %w[ROLLBACK COMMIT]
    abort "Expected PostgreSQL to acknowledge ROLLBACK in the baseline and COMMIT in the mutation"
  end
  transaction_violations = check_inventory(transaction_end, :inventory_balance)
  prove_mismatch(baseline, "TransactionEndMismatch.lean", transaction_end)

  schema = File.binread(PostgresRuntime::SCHEMA_SQL)
  corrected_key = database.duplicate_stock_key
  abort "The baseline must reject duplicate ids: #{corrected_key.inspect}" unless corrected_key == { sqlstate: "23505", quantities: [1] }
  without_key = schema.sub(" PRIMARY KEY", "")
  abort "Schema mutation did not remove the primary key" if without_key == schema
  duplicate_key = PostgresRuntime.with_database(url, schema_sql: without_key, &:duplicate_stock_key)
  abort "Expected two rows with id 1: #{duplicate_key.inspect}" unless duplicate_key == { sqlstate: nil, quantities: [1, 2] }

  trigger = File.binread(File.join(__dir__, "fixtures/postgres/extra_decrement.sql"))
  db_trigger = PostgresRuntime.with_database(url, schema_sql: schema + trigger) { |db| db.single(SAFE_SQL, 2, 2) }
  validate(db_trigger, [-1], -1, 2)
  trigger_violations = check_inventory(db_trigger, :negative_stock, :inventory_balance)
  prove_mismatch(baseline, "DatabaseTriggerMismatch.lean", db_trigger)

  checked_sql = cases.fetch(:waiting_after_commit)
  prove_mismatch(translation, "TranslationMismatch.lean", checked_sql)

  {
    ruby_binding: { detected_by: :model_mismatch, violations: ruby_violations, baseline: corrected_binding, observed: ruby_binding },
    transaction_end: { detected_by: :model_mismatch, violations: transaction_violations, baseline: corrected_rollback, observed: transaction_end },
    missing_primary_key: { detected_by: :unique_key_contract, baseline: corrected_key, observed: duplicate_key },
    database_trigger: { detected_by: :model_mismatch, violations: trigger_violations, baseline: corrected_binding, observed: db_trigger },
    sql_translation: { detected_by: :proof_rejection_and_model_mismatch, observed: checked_sql }
  }
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

  generated = PostgresUpdateToLean.generate(SAFE_SQL)
  wrong_translation = generated.sub("⟨true, true⟩", "⟨false, true⟩")
  abort "Translation mutation did not change the generated instruction" if wrong_translation == generated
  translation = compile_sql(parent, "translation", SAFE_SQL, generated: wrong_translation)
  proof(translation, "NoOversell", success: false)

  PostgresRuntime.with_database(url) do |database|
    puts "PostgreSQL server_version_num: #{database.version}"
    max_bigint = 2**63 - 1
    cases = {
      waiting_after_commit: database.overlapping(SAFE_SQL, first_finish: :commit),
      waiting_after_rollback: database.overlapping(SAFE_SQL, first_finish: :rollback),
      negative_request: database.single(SAFE_SQL, 0, -1),
      zero_request: database.single(SAFE_SQL, 0, 0),
      exact_request: database.single(SAFE_SQL, 2, 2),
      bigint_boundary: database.single(SAFE_SQL, max_bigint, max_bigint)
    }
    validate(cases.fetch(:waiting_after_commit), [0, nil], 0, 1, blocked: true)
    validate(cases.fetch(:waiting_after_rollback), [0, 0], 0, 1, blocked: true)
    validate(cases.fetch(:negative_request), [nil], 0, 0)
    validate(cases.fetch(:zero_request), [nil], 0, 0)
    validate(cases.fetch(:exact_request), [0], 0, 2)
    validate(cases.fetch(:bigint_boundary), [0], 0, max_bigint)
    cases.each_value { |scenario| check_inventory(scenario) }
    match_actual(baseline, cases)
    publish("baseline", baseline, cases, "PROVEN_CONDITIONAL", axioms)

    overdraw = database.overlapping(overdraw_sql, first_finish: :commit)
    validate(overdraw, [0, -1], -1, 2, blocked: true)
    overdraw_violations = check_inventory(overdraw, :negative_stock, :oversell)
    match_actual(oversell, { missing_stock_guard: overdraw })
    publish("oversell", oversell, { missing_stock_guard: overdraw }, "COUNTEREXAMPLE", oversell_axioms)

    negative_request = database.single(negative_sql, 0, -1)
    validate(negative_request, [1], 1, -1)
    negative_violations = check_inventory(negative_request, :negative_reserved)
    match_actual(negative, { missing_positive_guard: negative_request })
    publish("negative", negative, { missing_positive_guard: negative_request }, "COUNTEREXAMPLE", negative_axioms)

    layers = {
      missing_stock_guard: { detected_by: :counterexample, violations: overdraw_violations, observed: overdraw },
      missing_positive_guard: { detected_by: :counterexample, violations: negative_violations, observed: negative_request }
    }.merge(verify_layer_mutations(url, baseline, translation, cases, database))
    publish_layer_checks(baseline, translation, layers)
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
