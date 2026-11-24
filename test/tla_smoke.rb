require "erb"
require "fileutils"
require "tmpdir"
require_relative "../lib/integer_expression"
require_relative "../lib/tlc"
require_relative "tla_unit_check"

SOURCE = File.expand_path("../example/app/services/reservation_decision.rb", __dir__)
MODEL = File.expand_path("../model/tla", __dir__)
UNIT_TEST = File.expand_path("tla_reservation_test.rb", __dir__)

def check(source, directory)
  namespace = Module.new
  namespace.module_eval(File.read(source), source, 1)
  method = namespace.const_get(:ReservationDecision, false).method(:next_stock)
  expression = IntegerExpression.new(method, module_name: :ReservationDecision, parameters: %i[observed available]).to_tla
  template = ERB.new(File.read(File.join(MODEL, "ReservationCheck.tla.erb")))
  File.write(File.join(directory, "ReservationCheck.tla"), template.result_with_hash(expression: expression))
  FileUtils.cp(File.join(MODEL, "ReservationCheck.cfg"), directory)
  Tlc.counterexample(directory, "ReservationCheck")
end

Dir.mktmpdir("keisiki-tlc-replay-") do |directory|
  baseline = File.join(directory, "baseline")
  Dir.mkdir(baseline)
  abort "Unmodified reservation code violated the TLA+ specification" if check(SOURCE, baseline)
  puts "TLC: no reservation outcome differed from the specification in the two-order model"

  original = File.read(SOURCE)
  variants = {
    "stale_read" => original.sub("if available > 0\n      available - 1", "if observed > 0\n      observed - 1"),
    "last_item_denied" => original.sub("if available > 0", "if available > 1"),
    "stock_not_decremented" => original.sub("available - 1", "available")
  }
  variants.each do |name, mutated|
    abort "Mutation did not change the Ruby source: #{name}" if mutated == original

    scenario = File.join(directory, name)
    Dir.mkdir(scenario)
    source = File.join(scenario, "reservation_decision.rb")
    File.write(source, mutated)
    trace = check(source, scenario)
    abort "Missing TLC counterexample for #{name}" unless trace

    events = trace.drop(1).map { |state| state.fetch("event") }
    expected = events.select { |event| event.fetch("stage") == "commit" }.to_h do |event|
      [event.fetch("request"), event.fetch("expected")]
    end
    abort "Expected two completed reservations" unless events.size == 4 && expected.size == 2

    order = events.map { |event| "#{event.fetch("request")}.#{event.fetch("stage")}" }
    puts "TLC #{name}: #{order.join(" -> ")}, expected=#{expected.inspect}"
    fixture = File.join(scenario, "counterexample_fixture.json")
    File.write(fixture, JSON.pretty_generate({ "steps" => events, "expected" => expected }))
    TlaUnitCheck.publish(name, fixture, File.join(scenario, "counterexample.json"))
    env = { "TLA_TRACE_FIXTURE" => fixture, "DECISION_SOURCE" => source }
    TlaUnitCheck.run(UNIT_TEST, env: env, failure: "Reservation outcomes differ from the TLA+ trace")
    TlaUnitCheck.run(UNIT_TEST, env: env.merge("DECISION_SOURCE" => SOURCE))
  end
end
