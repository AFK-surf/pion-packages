SELECT * FROM t WHERE b = E'it\'s' AND c = 1; -- trailing
CREATE FUNCTION f() RETURNS int AS $$ SELECT 'it''s' $$ LANGUAGE sql;
SELECT 2;
