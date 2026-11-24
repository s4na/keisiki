Rails.application.routes.draw do
  post "/checkout/quote", to: "checkout#quote"
  get "/stock/remaining", to: "stock#remaining"
  post "/stock/reservations", to: "stock#reserve"
end
