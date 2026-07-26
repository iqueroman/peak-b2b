-- tests/00_harness.sql
--
-- Minimal assertion harness. Deliberately not pgTAP: pgTAP is an extension,
-- and the pipeline's whole point is that it runs on a stock Postgres with no
-- credentials and nothing to install. Twenty lines of plpgsql buys the same
-- thing here.
--
-- Every assertion is recorded rather than raised, so one run reports every
-- failure at once. 99_report.sql is what actually fails the build.

DROP SCHEMA IF EXISTS test CASCADE;
CREATE SCHEMA test;

CREATE TABLE test.result (
    seq         serial PRIMARY KEY,
    suite       text    NOT NULL,
    label       text    NOT NULL,
    expected    text    NOT NULL,
    actual      text    NOT NULL,
    passed      boolean NOT NULL,
    note        text            -- why an expectation differs from the ticket
);

-- expect(): the only assertion. Numeric equality, because every claim this
-- pipeline makes is a count that either reconciles or does not.
CREATE FUNCTION test.expect(
    p_suite    text,
    p_label    text,
    p_expected numeric,
    p_actual   numeric,
    p_note     text DEFAULT NULL
) RETURNS void LANGUAGE sql AS $$
    INSERT INTO test.result (suite, label, expected, actual, passed, note)
    VALUES (p_suite, p_label, p_expected::text, p_actual::text,
            p_expected = p_actual, p_note);
$$;


-- Assertions return void; silence them so the report is the only output.
\o /dev/null
