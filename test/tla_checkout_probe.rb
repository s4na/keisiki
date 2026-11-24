require_relative "tla_checkout_subject"
require_relative "../lib/tlc_oracle"

components = [
  [CheckoutFulfillment.units(3, 1), 1],
  [CheckoutPricing.subtotal(3), 120],
  [CheckoutPricing.volume_discount(3, true), 20],
  [CheckoutPricing.volume_discount(2, true), 0],
  [CheckoutPricing.coupon_discount(1, true), 20],
  [CheckoutPricing.coupon_discount(0, true), 0],
  [CheckoutShipping.fee(3, 100), 0],
  [CheckoutShipping.fee(3, 80), 12]
]
abort "An individual checkout policy failed" unless components.all? { |actual, expected| actual == expected }

cases = JSON.parse($stdin.read).map { |row| { arguments: [row.fetch("input")], expected: row.fetch("expected") } }
isolated = case ARGV.fetch(0)
when "partial_volume"
  cases.reject do |entry|
    input = entry.fetch(:arguments).first
    input.fetch("volume_offer") && input.fetch("requested") > input.fetch("available")
  end
when "stacked_shipping"
  cases.reject do |entry|
    input = entry.fetch(:arguments).first
    input.fetch("volume_offer") && input.fetch("coupon")
  end
when "baseline"
  cases
else
  abort "Unknown checkout scenario"
end
subject = TlaUnitSubject.method(:call)
abort "A quote without the target interaction failed" if TlcOracle.first_mismatch(isolated, subject)

witness = isolated.size == cases.size ? nil : TlcOracle.first_mismatch(cases, subject)
puts JSON.generate({ components_checked: components.size, isolated_cases: isolated.size, witness: witness })
