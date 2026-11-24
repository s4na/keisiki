require "fileutils"
require "tmpdir"
require_relative "../lib/tlc_minitest"
require_relative "../lib/tlc_oracle"
require_relative "tla_stock_mutations"
require_relative "tla_unit_check"

SOURCE = File.expand_path("../example/app/services/stock.rb", __dir__)
MODEL = File.expand_path("../model/tla", __dir__)
ADAPTER = File.expand_path("tla_stock_subject.rb", __dir__)
BANDS = { "small" => 0, "large" => 2**63 }.freeze

def stock_method(source)
  namespace = Module.new
  namespace.module_eval(File.read(source), source, 1)
  namespace.const_get(:Stock, false).method(:remaining)
end

Dir.mktmpdir("keisiki-tlc-oracle-") do |directory|
  FileUtils.cp(Dir[File.join(MODEL, "StockCases.*")], directory)
  cases = TlcOracle.cases(directory, "StockCases").map do |row|
    origin = BANDS.fetch(row.fetch("band"))
    {
      arguments: [origin + row.fetch("stock"), origin + row.fetch("quantity")],
      expected: BANDS.fetch(row.fetch("expectedBand")) + row.fetch("expectedOffset")
    }
  end
  unless cases.size == 34 && cases.map { |entry| entry.fetch(:arguments) }.uniq.size == 34
    abort "Expected 34 distinct model cases"
  end

  abort "Unmodified code disagreed with the TLA+ oracle" if TlcOracle.first_mismatch(cases, stock_method(SOURCE))
  puts "TLC oracle: all #{cases.size} modeled inputs agree with the original Ruby implementation"
  TlaUnitCheck.publish("model", File.join(directory, "cases.json"))

  original = File.read(SOURCE)
  variants = TlaStockMutations.small(original).merge(
    "large_signed_boundary" => TlaStockMutations.large(original),
    "ruby_method_call" => TlaStockMutations.ruby_method_call(original)
  )
  variants.each do |name, mutated|
    scenario = File.join(directory, name)
    Dir.mkdir(scenario)
    source = File.join(scenario, "stock.rb")
    File.write(source, mutated)
    witness = TlcOracle.first_mismatch(cases, stock_method(source))
    abort "No implementation mismatch for #{name}" unless witness

    puts "TLC oracle #{name}: #{witness.inspect}"
    test = File.join(scenario, "counterexample_test.rb")
    TlcMinitest.write(test, arguments: witness.fetch(:arguments), expected: witness.fetch(:expected))
    witness_file = File.join(scenario, "witness.json")
    File.write(witness_file, JSON.pretty_generate(witness))
    TlaUnitCheck.publish(name, test, witness_file)
    TlaUnitCheck.run(test, env: { "TLA_UNIT_ADAPTER" => ADAPTER, "STOCK_SOURCE" => source }, failure: "Actual: #{witness.fetch(:actual)}")
    TlaUnitCheck.run(test, env: { "TLA_UNIT_ADAPTER" => ADAPTER, "STOCK_SOURCE" => SOURCE })
  end
end
