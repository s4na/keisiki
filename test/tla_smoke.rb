require "erb"
require "fileutils"
require "tmpdir"
require_relative "../lib/integer_expression"
require_relative "../lib/tlc"
require_relative "../lib/tlc_minitest"
require_relative "tla_stock_mutations"
require_relative "tla_unit_check"

SOURCE = File.expand_path("../example/app/services/stock.rb", __dir__)
MODEL = File.expand_path("../model/tla", __dir__)
ADAPTER = File.expand_path("tla_stock_subject.rb", __dir__)

def check(source, directory)
  namespace = Module.new
  namespace.module_eval(File.read(source), source, 1)
  method = namespace.const_get(:Stock, false).method(:remaining)
  expression = IntegerExpression.new(method, module_name: :Stock, parameters: %i[stock quantity]).to_tla
  template = ERB.new(File.read(File.join(MODEL, "StockCheck.tla.erb")))
  File.write(File.join(directory, "StockCheck.tla"), template.result_with_hash(expression: expression))
  FileUtils.cp(File.join(MODEL, "StockCheck.cfg"), directory)
  Tlc.counterexample(directory, "StockCheck")
end

Dir.mktmpdir("keisiki-tlc-unit-") do |directory|
  baseline = File.join(directory, "baseline")
  Dir.mkdir(baseline)
  abort "Unmodified stock code violated the TLA+ specification" if check(SOURCE, baseline)
  puts "TLC: baseline conforms for all 25 modeled input pairs"

  original = File.read(SOURCE)
  TlaStockMutations.small(original).each do |name, mutated|
    scenario = File.join(directory, name)
    Dir.mkdir(scenario)
    source = File.join(scenario, "stock.rb")
    File.write(source, mutated)
    trace = check(source, scenario)
    abort "Missing TLC counterexample for #{name}" unless trace

    state = trace.last
    arguments = [state.fetch("inputStock"), state.fetch("inputQuantity")]
    expected = state.fetch("expected")
    actual = state.fetch("actual")
    puts "TLC #{name}: arguments=#{arguments.inspect}, expected=#{expected}, actual=#{actual}"
    test = File.join(scenario, "counterexample_test.rb")
    TlcMinitest.write(test, arguments: arguments, expected: expected)
    TlaUnitCheck.publish(name, test, File.join(scenario, "counterexample.json"))
    TlaUnitCheck.run(test, env: { "TLA_UNIT_ADAPTER" => ADAPTER, "STOCK_SOURCE" => source }, failure: "Actual: #{actual}")
    TlaUnitCheck.run(test, env: { "TLA_UNIT_ADAPTER" => ADAPTER, "STOCK_SOURCE" => SOURCE })
  end

  unsupported = File.join(directory, "method_call.rb")
  File.write(unsupported, TlaStockMutations.ruby_method_call(original))
  begin
    check(unsupported, baseline)
    abort "Expected a Ruby method call to be rejected"
  rescue IntegerExpression::Unsupported
    puts "TLC: Ruby method calls are unsupported by the source translator"
  end
end
