require "fileutils"
require "open3"
require "rbconfig"

module TlaUnitCheck
  def self.run(test, env:, failure: nil)
    output, status = Open3.capture2e(env, RbConfig.ruby, test)
    expected_exit = failure ? 1 : 0
    failures = failure ? 1 : 0
    expected_summary = "1 runs, 1 assertions, #{failures} failures, 0 errors"
    unless status.exitstatus == expected_exit && output.include?(expected_summary) && (!failure || output.include?(failure))
      abort "Unexpected Minitest result (exit #{status.exitstatus}):\n#{output}"
    end
    puts output
  end

  def self.publish(scenario, *files)
    return unless ENV["TLA_ARTIFACT_DIR"]

    directory = File.join(ENV.fetch("TLA_ARTIFACT_DIR"), scenario)
    FileUtils.mkdir_p(directory)
    FileUtils.cp(files, directory)
  end
end
