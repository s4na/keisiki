CREATE FUNCTION keisiki_decrement_again() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.quantity := NEW.quantity - 1;
  RETURN NEW;
END;
$$;

CREATE TRIGGER keisiki_decrement_again
BEFORE UPDATE ON keisiki_stock
FOR EACH ROW EXECUTE FUNCTION keisiki_decrement_again();
