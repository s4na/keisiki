Rails.application.routes.draw do
  get "/stock/remaining", to: "stock#remaining"
  post "/stock/reservations", to: "stock#reserve"
end
