CREATE TABLE stocks (
  id bigint PRIMARY KEY,
  quantity bigint NOT NULL CHECK (quantity >= 0)
);

CREATE TABLE reservations (
  id varchar(80) PRIMARY KEY,
  stock_id bigint NOT NULL REFERENCES stocks (id),
  quantity bigint NOT NULL CHECK (quantity > 0)
);
