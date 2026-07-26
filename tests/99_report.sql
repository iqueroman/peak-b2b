-- tests/99_report.sql
--
-- Prints every assertion, then fails the process if any did not pass. The full
-- table always prints: when a count moves, you want to see which one, not just
-- that something did.

\o
\pset border 2
\pset title 'Assertions'

SELECT CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS status,
       suite,
       label,
       expected,
       actual,
       note
  FROM test.result
 ORDER BY seq;

DO $$
DECLARE
    n_fail int;
    n_all  int;
BEGIN
    SELECT count(*) FILTER (WHERE NOT passed), count(*) INTO n_fail, n_all
      FROM test.result;

    IF n_fail > 0 THEN
        RAISE EXCEPTION '% of % assertions failed', n_fail, n_all;
    END IF;

    RAISE NOTICE 'all % assertions passed', n_all;
END $$;
