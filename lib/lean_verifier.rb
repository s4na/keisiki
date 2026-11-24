require "json"
require "open3"
require "tmpdir"
require_relative "ruby_to_lean"

class LeanVerifier
  ROOT = File.expand_path("..", __dir__)
  ALLOWED_AXIOMS = %w[propext Classical.choice Quot.sound].freeze
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
    output, status = Open3.capture2e("lake", "build", chdir: ROOT)
    return Result.new("ERROR", {}, output) unless status.success?

    Dir.mktmpdir("keisiki-lean-") do |directory|
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
      output, status = lean(directory, module_name, "-o", "#{module_name}.olean")
      next if status.success?

      result = module_name == "VerificationCertificate" ? "UNKNOWN" : "ERROR"
      return Result.new(result, {}, output)
    end

    File.write(File.join(directory, "Audit.lean"), audit_source(counterexample))
    output, status = lean(directory, "Audit")
    return Result.new("UNKNOWN", {}, output) unless status.success?

    axioms = audited_axioms(output)
    unless axioms && (axioms - ALLOWED_AXIOMS).empty?
      return Result.new("UNKNOWN", {}, "Proof depends on unapproved axioms or the audit is incomplete:\n#{output}")
    end

    data = { model_status: counterexample ? "REFUTED" : "PROVEN", axioms: axioms }
    if counterexample
      line = output.lines.find { |entry| entry.start_with?("keisiki-witness=") }
      return Result.new("ERROR", {}, output) unless line

      data[:witness] = JSON.parse(line.delete_prefix("keisiki-witness="))
    end
    Result.new(counterexample ? "COUNTEREXAMPLE" : "PROVEN_CONDITIONAL", data, "")
  end

  def lean(directory, module_name, *options)
    search_path = [directory, File.join(ROOT, ".lake/build/lib/lean")].join(File::PATH_SEPARATOR)
    Open3.capture2e(
      { "LEAN_PATH" => search_path }, "lean", "-DwarningAsError=true",
      *options, "#{module_name}.lean", chdir: directory
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
      #print axioms checkedCertificate
      #print axioms Keisiki.invoke_lower
    LEAN
    return source unless counterexample

    source + <<~'LEAN'
      #eval IO.println (
        "keisiki-witness={\"arguments\":[" ++ String.intercalate "," (Verification.witness.arguments.map toString) ++
        "],\"result\":" ++ toString Verification.witness.result ++ "}")
    LEAN
  end

  def audited_axioms(output)
    axiom_lists = %w[checkedCertificate Keisiki.invoke_lower].map do |name|
      line = output.lines.find { |entry| entry.start_with?("'#{name}'") }&.strip
      return unless line
      next [] if line == "'#{name}' does not depend on any axioms"

      match = /depends on axioms: \[([^\]]*)\]\z/.match(line)
      return unless match

      match[1].split(",").map(&:strip)
    end
    axiom_lists.flatten.uniq.sort
  end
end
