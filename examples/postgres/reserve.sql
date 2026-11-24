UPDATE ONLY keisiki_stock
SET quantity = quantity - $1::bigint
WHERE id = 1
  AND quantity >= $1::bigint
  AND $1::bigint > 0
RETURNING quantity;
