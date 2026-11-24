require "rails"
require "action_controller/railtie"
require "active_record/railtie"

module ReservationExample
  class Application < Rails::Application
    config.load_defaults 8.1
    config.root = File.expand_path("..", __dir__)
    config.api_only = true
    config.eager_load = false
    config.logger = Logger.new(File::NULL)
    config.secret_key_base = "keisiki-reservation-example-for-tests-only"
  end
end
