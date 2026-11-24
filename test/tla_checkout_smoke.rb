require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/tlc_minitest"
require_relative "../lib/tlc_oracle"
require_relative "tla_unit_check"

EXAMPLE = File.expand_path("../example", __dir__)
MODEL = File.expand_path("../model/tla", __dir__)
ADAPTER = File.expand_path("tla_checkout_subject.rb", __dir__)
PROBE = File.expand_path("tla_checkout_probe.rb", __dir__)
QUOTE = "app/services/checkout_quote.rb"

def probe(example, cases, scenario)
  output, errors, status = Open3.capture3(
    { "CHECKOUT_EXAMPLE" => example }, RbConfig.ruby, PROBE, scenario, stdin_data: JSON.generate(cases)
  )
  abort "Checkout probe failed in #{scenario}:\n#{output}#{errors}" unless status.success?

  JSON.parse(output)
end

Dir.mktmpdir("keisiki-tlc-checkout-") do |directory|
  FileUtils.cp(Dir[File.join(MODEL, "QuoteCases.*")], directory)
  cases = TlcOracle.cases(directory, "QuoteCases")
  unless cases.size == 100 && cases.map { |row| row.fetch("input") }.uniq.size == 100
    abort "Expected 100 distinct checkout inputs from the model"
  end

  baseline = probe(EXAMPLE, cases, "baseline")
  puts "TLC checkout: original Rails endpoint matched all #{baseline.fetch("isolated_cases")} modeled quotes"
  TlaUnitCheck.publish("checkout_model", File.join(directory, "cases.json"))

  variants = {
    "partial_volume" => ["volume_discount(fulfilled, volume_offer)", "volume_discount(requested, volume_offer)"],
    "stacked_shipping" => ["CheckoutShipping.fee(fulfilled, merchandise)", "CheckoutShipping.fee(fulfilled, subtotal)"]
  }
  variants.each do |name, (original, replacement)|
    scenario = File.join(directory, name)
    FileUtils.cp_r(EXAMPLE, scenario)
    source = File.join(scenario, QUOTE)
    code = File.read(source)
    abort "Could not locate #{original} to mutate" unless code.include?(original)

    File.write(source, code.sub(original, replacement))
    result = probe(scenario, cases, name)
    witness = result.fetch("witness")
    abort "No failing checkout found for #{name}" unless witness

    puts "TLC checkout #{name}: #{result.fetch("components_checked")} policy checks and #{result.fetch("isolated_cases")} quotes without the interaction passed"
    puts "TLC checkout #{name}: #{witness.inspect}"
    test = File.join(directory, "#{name}_test.rb")
    TlcMinitest.write(test, arguments: witness.fetch("arguments"), expected: witness.fetch("expected"))
    witness_file = File.join(directory, "#{name}_witness.json")
    File.write(witness_file, JSON.pretty_generate(witness))
    TlaUnitCheck.publish("checkout_#{name}", test, witness_file)
    env = { "TLA_UNIT_ADAPTER" => ADAPTER, "CHECKOUT_EXAMPLE" => scenario }
    TlaUnitCheck.run(test, env: env, failure: "TlcCounterexampleTest#test_result_matches_the_specification")
    TlaUnitCheck.run(test, env: env.merge("CHECKOUT_EXAMPLE" => EXAMPLE))
  end
end
