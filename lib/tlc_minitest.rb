require "json"

module TlcMinitest
  # The adapter exposes TlaUnitSubject.call(*arguments).
  def self.write(path, arguments:, expected:)
    payload = JSON.generate({ "arguments" => arguments, "expected" => expected })
    File.write(path, <<~RUBY)
      require "json"
      require "minitest/autorun"
      require ENV.fetch("TLA_UNIT_ADAPTER")

      class TlcCounterexampleTest < Minitest::Test
        def test_result_matches_the_specification
          test_case = JSON.parse(#{payload.dump})
          assert_equal test_case.fetch("expected"), TlaUnitSubject.call(*test_case.fetch("arguments"))
        end
      end
    RUBY
  end
end
