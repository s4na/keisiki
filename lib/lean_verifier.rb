require "json"
require "open3"
require "tmpdir"
require_relative "ruby_to_lean"

class LeanVerifier
  ROOT = File.expand_path("..", __dir__)
  SOURCE_PREMISES = [
    "The pinned Prism parser and AST emitter agree with CRuby 4.0 on the supported source.",
    "The supplied modules are loaded as written into a fresh environment; no methods or core Integer operations are redefined.",
    "Arguments are Ruby Integers and the complete call graph is included."
  ].freeze

  Result = Data.define(:status, :data, :diagnostics)

  def verify(claim:, certificate:, sources:, counterexample: false)
    generated = RubyToLean.generate(sources)
    claim_bytes = File.binread(claim)
    certificate_bytes = File.binread(certificate)
    toolchain = File.read(File.join(ROOT, "lean-toolchain"))
    output, status = Open3.capture2e("lake", "build", chdir: ROOT)
    return Result.new("ERROR", {}, output) unless status.success?

    Dir.mktmpdir("keisiki-lean-") do |directory|
      File.write(File.join(directory, "lean-toolchain"), toolchain)
      File.write(File.join(directory, "GeneratedRuby.lean"), generated)
      File.binwrite(File.join(directory, "VerificationClaim.lean"), claim_bytes)
      File.binwrite(File.join(directory, "VerificationCertificate.lean"), certificate_bytes)

      result = check_modules(directory, counterexample)
      result.with(data: {
        generated_sha256: Digest::SHA256.hexdigest(generated),
        claim_sha256: Digest::SHA256.hexdigest(claim_bytes),
        certificate_sha256: Digest::SHA256.hexdigest(certificate_bytes),
        ruby_version: "#{RUBY_ENGINE} #{RUBY_VERSION}",
        prism_version: Prism::VERSION,
        lean_toolchain: toolchain.strip,
        source_premises: SOURCE_PREMISES
      }.merge(result.data))
    end
  rescue RubyToLean::Unsupported => error
    Result.new("UNSUPPORTED", {}, error.message)
  rescue SystemCallError => error
    Result.new("ERROR", {}, error.message)
  end

  private

  def check_modules(directory, counterexample)
    %w[GeneratedRuby VerificationClaim VerificationCertificate].each do |module_name|
      output, status = lean(directory, "-o", "#{module_name}.olean", "#{module_name}.lean")
      next if status.success?

      result = module_name == "VerificationCertificate" ? "UNKNOWN" : "ERROR"
      return Result.new(result, {}, output)
    end

    File.write(File.join(directory, "Audit.lean"), audit_source(counterexample))
    output, status = lean(directory, "-o", "Audit.olean", "Audit.lean")
    return Result.new("UNKNOWN", {}, output) unless status.success?

    witness = nil
    if counterexample
      witnesses = output.lines.grep(/\Akeisiki-witness=/)
      return Result.new("UNKNOWN", {}, "Expected one witness report:\n#{output}") unless witnesses.size == 1

      candidate = JSON.parse(witnesses.first.delete_prefix("keisiki-witness="))
      unless candidate.is_a?(Hash) && candidate["arguments"].is_a?(Array) &&
          candidate["arguments"].all?(Integer) && candidate["result"].is_a?(Integer)
        return Result.new("UNKNOWN", {}, "Expected integer arguments and result in the witness")
      end

      witness = candidate.slice("arguments", "result")
    end
    arguments = witness ? [JSON.generate(witness)] : []
    report, status = lean(directory, "--run", File.join(ROOT, "script/audit.lean"), *arguments)
    return Result.new("UNKNOWN", {}, report) unless status.success?

    data = { model_status: counterexample ? "REFUTED" : "PROVEN", axioms: JSON.parse(report) }
    data[:witness] = witness if witness
    Result.new(counterexample ? "COUNTEREXAMPLE" : "PROVEN_CONDITIONAL", data, "")
  rescue JSON::ParserError => error
    Result.new("UNKNOWN", {}, "Invalid audit data: #{error.message}")
  end

  def lean(directory, *arguments)
    search_path = [directory, File.join(ROOT, ".lake/build/lib/lean")].join(File::PATH_SEPARATOR)
    Open3.capture2e(
      { "LEAN_PATH" => search_path }, "lean", "-DwarningAsError=true", *arguments, chdir: directory
    )
  end

  def audit_source(counterexample)
    proposition = if counterexample
      "Verification.claim.RefutesAt GeneratedRuby.program Verification.witness"
    else
      "Verification.claim.Holds GeneratedRuby.program"
    end
    source = <<~LEAN
      import GeneratedRuby
      import VerificationClaim
      import VerificationCertificate

      theorem checkedCertificate : #{proposition} := Verification.certificate
    LEAN
    return source unless counterexample

    source + <<~'LEAN'
      #eval IO.println (
        "keisiki-witness={\"arguments\":[" ++ String.intercalate "," (Verification.witness.arguments.map toString) ++
        "],\"result\":" ++ toString Verification.witness.result ++ "}")
    LEAN
  end
end
