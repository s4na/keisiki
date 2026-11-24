require "json"
require "open3"

module Tlc
  class Error < StandardError; end

  def self.run(directory, model, *options)
    jar = File.expand_path(ENV.fetch("TLA2TOOLS_JAR"))
    Open3.capture2e(
      "java", "-Xmx512m", "-jar", jar, "-workers", "1", "-nowarning",
      "-noGenerateSpecTE", *options, model, chdir: directory
    )
  end

  def self.counterexample(directory, model)
    trace = File.join(directory, "counterexample.json")
    raise Error, "Counterexample output already exists" if File.exist?(trace)

    output, status = run(directory, model, "-dumpTrace", "json", "counterexample.json")
    case status.exitstatus
    when 0
      raise Error, "Unexpected trace for a passing model" if File.exist?(trace)
    when 12
      unless File.file?(trace)
        raise Error, "TLC reported an invariant violation without a trace:\n#{output}"
      end

      states = JSON.parse(File.read(trace)).fetch("counterexample").fetch("state")
      raise Error, "Empty counterexample trace" if states.empty?

      states.map { |_index, state| state }
    else
      raise Error, "TLC failed (exit #{status.exitstatus}):\n#{output}"
    end
  end
end
