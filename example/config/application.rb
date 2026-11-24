require "rails"
require "action_controller/railtie"

module StockExample
  class Application < Rails::Application
    config.load_defaults 8.1
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.logger = Logger.new(File::NULL)
    config.secret_key_base = "stock-example-for-tests-only"

    config.after_initialize do
      config.x.reservations = ReservationStore.new(1)
    end
  end
end
