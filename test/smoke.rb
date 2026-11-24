require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/ruby_to_lean"

ROOT = File.expand_path("..", __dir__)
VERIFY = File.join(ROOT, "script/verify.rb")
CONTRACT = File.join(ROOT, "examples/lean/BudgetContract.lean")
PROOF = File.join(ROOT, "examples/lean/BudgetProof.lean")
BUDGET = File.join(ROOT, "examples/ruby/budget.rb")
RULES = File.join(ROOT, "examples/ruby/budget_rules.rb")

def verify(expected_status, expected_exit, certificate: PROOF, sources: [BUDGET, RULES], refute: false)
  flags = refute ? ["--counterexample"] : []
  out, err, status = Open3.capture3(RbConfig.ruby, VERIFY, *flags, CONTRACT, certificate, *sources, chdir: ROOT)
  abort "Expected #{expected_status}, got exit #{status.exitstatus}: #{out}\n#{err}" unless status.exitstatus == expected_exit

  result = JSON.parse(out)
  abort "Expected #{expected_status}: #{out}\n#{err}" unless result.fetch("status") == expected_status

  puts "#{expected_status} #{result["witness"] || File.basename(certificate)}"
  [result, err]
end

def replay(sources, entry, arguments)
  runner = <<~'RUBY'
    paths, entry, arguments = JSON.parse(ARGV.fetch(0))
    paths.each { |path| require path }
    owner, method = entry.split(".")
    puts JSON.generate(Object.const_get(owner, false).public_send(method, *arguments))
  RUBY
  out, err, status = Open3.capture3(RbConfig.ruby, "-rjson", "-e", runner, JSON.generate([sources, entry, arguments]))
  abort "CRuby replay failed for #{entry}: #{err}" unless status.success?

  JSON.parse(out)
end

def match_cruby(directory, sources, entry, cases)
  program = RubyToLean.generate(sources)
  checks = cases.map do |arguments|
    expected = replay(sources, entry, arguments)
    values = arguments.map { |number| "(#{number})" }.join(", ")
    "example : Keisiki.Source.invoke GeneratedRuby.program #{entry.dump} [#{values}] = .ok (#{expected}) := by rfl"
  end
  file = File.join(directory, "Conformance.lean")
  File.write(file, program + "\n" + checks.join("\n") + "\n")
  env = { "LEAN_PATH" => File.join(ROOT, ".lake/build/lib/lean") }
  out, status = Open3.capture2e(env, "lean", "-DwarningAsError=true", file, chdir: directory)
  abort "CRuby/Lean conformance failed:\n#{out}" unless status.success?

  puts "CRuby/Lean: #{cases.size} cases matched for #{entry}"
end

def publish(name, content)
  path = ENV["KEISIKI_ARTIFACT_DIR"]
  return unless path

  FileUtils.mkdir_p(path)
  File.write(File.join(path, name), content)
end

Dir.mktmpdir("keisiki-smoke-") do |directory|
  FileUtils.cp(File.join(ROOT, "lean-toolchain"), directory)
  original = RubyToLean.generate([BUDGET, RULES])
  copy = File.join(directory, "relocated.rb")
  FileUtils.cp(BUDGET, copy)
  unless original == RubyToLean.generate([RULES, copy])
    abort "The generated Lean is not byte-identical after reordering and relocating sources"
  end
  puts "Deterministic translation: identical bytes for reordered and relocated inputs"

  result, = verify("PROVEN_CONDITIONAL", 0)
  unless result.fetch("model_status") == "PROVEN" && result.fetch("generated_sha256") == Digest::SHA256.hexdigest(original)
    abort "The proved artifact does not match the generated Ruby AST"
  end
  publish("GeneratedRuby.lean", original)
  publish("proof-result.json", JSON.pretty_generate(result))

  arithmetic = File.join(__dir__, "fixtures/arithmetic.rb")
  match_cruby(
    directory, [BUDGET, RULES], "Budget.remaining",
    [[0, 0], [0, 1], [1, 0], [2, 2], [3, 2], [3, 4], [2**63, 2**63], [7, -1], [-2**70, 1]]
  )
  match_cruby(
    directory, [arithmetic], "ArithmeticFixture.choose",
    [[4, 3, 2], [3, 3, 2], [0, -1, 2], [2**70, 0, -1], [-4, 3, 2]]
  )
  # Integer boundary inputs adapted from ruby/spec core/integer/{plus,minus}_spec.rb.
  match_cruby(directory, [arithmetic], "ArithmeticFixture.combine", [[9, 2**64, 0], [2**64 + 76, 4, 0]])
  match_cruby(directory, [BUDGET, RULES], "Budget.difference", [[2_560_496, 2**64], [2**64 + 314, 2**64 + 42]])

  variants = [
    ["reversed_arguments", BUDGET, "approved(available, requested)", "approved(requested, available)", "ReversedArguments.lean"],
    ["exact_boundary", RULES, "requested > available", "requested > (available - 1)", "ExactBoundary.lean"]
  ]
  variants.each do |name, file, original_text, replacement, refutation|
    variant = File.join(directory, "#{name}.rb")
    source = File.read(file)
    abort "Mutation target is missing: #{name}" unless source.include?(original_text)

    File.write(variant, source.sub(original_text, replacement))
    sources = [BUDGET, RULES].map { |candidate| candidate == file ? variant : candidate }
    puts "Testing deliberate mutation: #{name}"
    verify("UNKNOWN", 3, sources: sources)
    witness_result, = verify(
      "COUNTEREXAMPLE", 10, certificate: File.join(ROOT, "examples/lean", refutation), sources: sources, refute: true
    )
    witness = witness_result.fetch("witness")
    arguments = witness.fetch("arguments")
    observed = replay(sources, "Budget.remaining", arguments)
    reference = replay([BUDGET, RULES], "Budget.remaining", arguments)
    unless observed == witness.fetch("result") && observed != reference && witness_result.fetch("model_status") == "REFUTED"
      abort "Kernel-checked counterexample did not reproduce in CRuby"
    end
    puts "CRuby replay #{name}: #{arguments.inspect} => #{observed}; original => #{reference}"
    publish("#{name}.json", JSON.pretty_generate(witness_result.merge("cruby_result" => observed, "original_result" => reference)))
  end

  unsupported = {
    "eval" => "module Probe; def self.f(x); eval(x); end; end",
    "recursive_call" => "module Probe; def self.f(x); self.f(x); end; end",
    "unknown_call" => "module Probe; def self.f(x); Missing.f(x); end; end",
    "duplicate_parameter" => "module Probe; def self.f(_x, _x); _x; end; end"
  }
  unsupported.each do |name, source|
    file = File.join(directory, "#{name}.rb")
    File.write(file, source)
    verify("UNSUPPORTED", 2, sources: [file])
  end

  invalid_certificate = File.join(directory, "InvalidCertificate.lean")
  File.write(invalid_certificate, <<~LEAN)
    import GeneratedRuby
    import VerificationClaim
    namespace Verification
    axiom certificate : claim.Holds GeneratedRuby.program
    end Verification
  LEAN
  _, diagnostic = verify("UNKNOWN", 3, certificate: invalid_certificate)
  abort "Missing custom-axiom rejection" unless diagnostic.include?("unapproved axioms") && diagnostic.include?("Verification.certificate")

  File.write(invalid_certificate, <<~LEAN)
    import GeneratedRuby
    import VerificationClaim
    namespace Verification
    theorem certificate : claim.Holds GeneratedRuby.program := by sorry
    end Verification
  LEAN
  _, diagnostic = verify("UNKNOWN", 3, certificate: invalid_certificate)
  abort "Missing sorry rejection" unless diagnostic.include?("sorry")

  File.write(invalid_certificate, <<~LEAN)
    import GeneratedRuby
    namespace Verification
    def claim : Keisiki.Contract := ⟨"Budget.remaining", fun _ => False, fun _ _ => True⟩
    theorem certificate : claim.Holds GeneratedRuby.program := by
      intro arguments pre
      exact False.elim pre
    end Verification
  LEAN
  _, diagnostic = verify("UNKNOWN", 3, certificate: invalid_certificate)
  abort "Missing replacement-claim rejection" unless diagnostic.include?("Verification.claim")

  proof_body = File.readlines(PROOF).reject { |line| line.start_with?("import ") }.join
  File.write(invalid_certificate, "import VerificationClaim\n#{original}\n#{proof_body}")
  mutant = File.join(directory, "reversed_arguments.rb")
  _, diagnostic = verify("UNKNOWN", 3, certificate: invalid_certificate, sources: [mutant, RULES])
  abort "Missing replacement-program rejection" unless diagnostic.include?("GeneratedRuby.")
end
