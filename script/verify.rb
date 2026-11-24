require_relative "../lib/lean_verifier"

counterexample = ARGV.first == "--counterexample"
ARGV.shift if counterexample
if ARGV.length < 3
  abort "Usage: ruby script/verify.rb [--counterexample] CLAIM.lean CERTIFICATE.lean SOURCE.rb [SOURCE.rb ...]"
end

claim, certificate, *sources = ARGV
result = LeanVerifier.new.verify(claim: claim, certificate: certificate, sources: sources, counterexample: counterexample)
warn result.diagnostics unless result.diagnostics.empty?
puts JSON.generate({ status: result.status }.merge(result.data))
exit({ "PROVEN_CONDITIONAL" => 0, "COUNTEREXAMPLE" => 10, "UNSUPPORTED" => 2, "UNKNOWN" => 3, "ERROR" => 4 }.fetch(result.status))
