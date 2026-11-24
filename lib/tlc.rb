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

end
