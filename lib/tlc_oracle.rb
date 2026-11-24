require_relative "tlc"

module TlcOracle
  def self.cases(directory, model)
    path = File.join(directory, "cases.json")
    raise Tlc::Error, "Oracle output already exists" if File.exist?(path)

    output, status = Tlc.run(directory, model)
    unless status.success? && File.file?(path)
      raise Tlc::Error, "TLC failed to export cases (exit #{status.exitstatus}):\n#{output}"
    end

    rows = JSON.parse(File.read(path))
    raise Tlc::Error, "Expected a nonempty array of model cases" unless rows.is_a?(Array) && !rows.empty?

    rows
  end

  def self.first_mismatch(cases, subject)
    cases.each do |entry|
      actual = subject.call(*entry.fetch(:arguments))
      return entry.merge(actual: actual) unless entry.fetch(:expected) == actual
    end
    nil
  end
end
