require "erb"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/integer_expression"

EXAMPLE = File.expand_path("../example", __dir__)
QUINT = File.expand_path("../node_modules/.bin/quint", __dir__)
TEMPLATE = File.expand_path("../model/reservations.qnt.erb", __dir__)
REPLAY = File.expand_path("replay_reservations.rb", __dir__)
DECISION_SOURCE = "app/services/reservation_decision.rb"
MAX_STEPS = 4

def verify(example, directory, expected_status, expected_exit)
  FileUtils.mkdir_p(directory)
  source = File.join(example, DECISION_SOURCE)
  namespace = Module.new
  namespace.module_eval(File.read(source), source, 1)
  method = namespace.const_get(:ReservationDecision, false).method(:next_stock)
  expression = IntegerExpression.new(method, module_name: :ReservationDecision, parameters: %i[observed available])
  decision = "pure def nextStock(observed: int, available: int): int = #{expression.to_quint}"
  File.write(File.join(directory, "reservations.qnt"), ERB.new(File.read(TEMPLATE)).result_with_hash(decision: decision))

  output, status = Open3.capture2e(
    QUINT, "verify", "reservations.qnt", "--invariant=noOversell", "--max-steps=#{MAX_STEPS}",
    "--out=result.json", "--out-itf=counterexample.itf.json", chdir: directory
  )
  result_path = File.join(directory, "result.json")
  abort "Quint produced no result (exit #{status.exitstatus}):\n#{output}" unless File.file?(result_path)

  result = JSON.parse(File.read(result_path))
  unless status.exitstatus == expected_exit && result["status"] == expected_status && result["errors"] == []
    abort "Unexpected Quint result (exit #{status.exitstatus}): #{result.slice("status", "errors").inspect}\n#{output}"
  end

  File.join(directory, "counterexample.itf.json")
end

Dir.mktmpdir("keisiki-reservations-") do |directory|
  verify(EXAMPLE, File.join(directory, "corrected"), "ok", 0)
  puts "Quint/Apalache: noOversell verified up to #{MAX_STEPS} steps"

  mutated_example = File.join(directory, "mutated-example")
  FileUtils.cp_r(EXAMPLE, mutated_example)
  source = File.join(mutated_example, DECISION_SOURCE)
  original = File.read(source)
  decision = "if available > 0\n      available - 1"
  abort "Could not locate the reservation decision to mutate" unless original.include?(decision)

  File.write(source, original.sub(decision, "if observed > 0\n      observed - 1"))
  trace = verify(mutated_example, File.join(directory, "mutant"), "violation", 1)
  abort "Quint reported a violation without a trace" unless File.file?(trace)

  puts "Quint/Apalache: noOversell violated when committing against the old stock value"
  { "mutant" => mutated_example, "corrected" => EXAMPLE }.each do |mode, example|
    abort "Failed to replay #{mode} in Rails" unless system(RbConfig.ruby, REPLAY, example, trace, mode)
  end
end
