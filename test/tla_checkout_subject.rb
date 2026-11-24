require "json"

ENV["RAILS_ENV"] = "test"
require File.join(ENV.fetch("CHECKOUT_EXAMPLE"), "config/application")
Rails.application.initialize!

module TlaUnitSubject
  def self.call(input)
    response = Rack::MockRequest.new(Rails.application).post(
      "/checkout/quote", "CONTENT_TYPE" => "application/json", input: JSON.generate(input)
    )
    unless response.status == 200
      raise "Checkout quote returned HTTP #{response.status} for #{input.inspect}"
    end

    JSON.parse(response.body)
  end
end
