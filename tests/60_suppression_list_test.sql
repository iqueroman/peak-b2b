-- tests/60_suppression_list_test.sql
--
-- The suppression list is the one table in this model that is empty on the
-- supplied data, and an empty table is indistinguishable from a broken one.
-- Every other rule can be checked by counting the rows it rejects; these three
-- can only be checked by asserting facts into the list and watching the ledger
-- move.
--
-- That is the whole reason this suite exists. The brief names partner conflicts
-- as something that "needs to be excluded", and answering that with a table
-- nobody has ever written a row to would be a claim, not a component.
--
-- Fixtures are inserted, asserted against, and deleted. The final assertion
-- checks the list is empty and the eligible count is back to 723, because a
-- test that leaves the database changed makes the next number a lie.

-- The catalogue: three reasons, three generated rules, at the top of precedence.
SELECT test.expect('suppression_list', 'reasons in the catalogue', 3,
                   (SELECT count(*) FROM suppression_reason));

SELECT test.expect('suppression_list', 'every reason has a rule the ledger may cite', 0,
                   (SELECT count(*) FROM suppression_reason s
                     WHERE NOT EXISTS (SELECT 1 FROM eligibility_rule r
                                        WHERE r.rule_name = 'list:' || s.reason)),
                   'rules are generated from the catalogue, so a reason cannot exist without one');

SELECT test.expect('suppression_list', 'asserted rules outrank every derived rule', 0,
                   (SELECT count(*) FROM eligibility_rule a, eligibility_rule b
                     WHERE a.rule_name LIKE 'list:%'
                       AND b.rule_name NOT LIKE 'list:%'
                       AND a.precedence > b.precedence));

SELECT test.expect('suppression_list', 'empty on the supplied data', 0,
                   (SELECT count(*) FROM suppression_list),
                   'no partner-relationship field exists in the CSV; source=partner_referral is the opposite');


-- --------------------------------------------------------------------------
--  Company scope. A partner agreement is written about an account, not a
--  person, so one row has to take a whole company off the list.
--  hammersmithstudio.co: 25 contacts, 22 of them currently eligible — the
--  largest eligible cluster in the file, which is exactly the shape of thing
--  a partner conflict costs you.
-- --------------------------------------------------------------------------

INSERT INTO suppression_list (suppression_id, reason, scope, company_id,
                              added_by, added_at, evidence)
SELECT norm.surrogate('suppression', 'test:partner:hammersmith'),
       'partner_conflict', 'company', c.company_id,
       'test fixture', config.as_of(),
       jsonb_build_object('agreement', 'reseller — do not approach direct')
  FROM company c WHERE c.primary_domain = 'hammersmithstudio.co';

SELECT test.expect('suppression_list', 'company scope expands to every contact', 25,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'list:partner_conflict'),
                   '25 contacts at hammersmithstudio.co, not the 1 row inserted');

SELECT test.expect('suppression_list', 'company scope removes its eligible contacts', 701,
                   (SELECT count(*) FROM eligibility_ledger WHERE decision = 'eligible'),
                   '723 - 22 eligible at that company');

SELECT test.expect('suppression_list', 'the ledger carries the writer and the evidence', 25,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'list:partner_conflict'
                       AND evidence->>'added_by' = 'test fixture'
                       AND evidence->>'company' = 'hammersmithstudio.co'),
                   'an asserted suppression is only auditable if the ledger names who asserted it');

DELETE FROM suppression_list;


-- --------------------------------------------------------------------------
--  Precedence. oakhausmarketing.agency is already suppressed company-wide as
--  a customer, so a partner conflict there changes no volume at all — it
--  changes what the rejection ledger *says*, which is the point of ordering
--  the rules by meaning rather than by convenience.
-- --------------------------------------------------------------------------

INSERT INTO suppression_list (suppression_id, reason, scope, company_id,
                              added_by, added_at)
SELECT norm.surrogate('suppression', 'test:partner:oakhaus'),
       'partner_conflict', 'company', c.company_id, 'test fixture', config.as_of()
  FROM company c WHERE c.primary_domain = 'oakhausmarketing.agency';

SELECT test.expect('suppression_list', 'asserted reason wins over company:customer', 26,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'list:partner_conflict'),
                   'all 26 were rejected as customers a moment ago');

SELECT test.expect('suppression_list', 'no volume change when it overlaps an existing rule', 723,
                   (SELECT count(*) FROM eligibility_ledger WHERE decision = 'eligible'));

SELECT test.expect('suppression_list', 'company:customer still fires underneath', 26,
                   (SELECT count(*) FROM rule_fired
                     WHERE rule_name = 'company:customer'
                       AND person_id IN (SELECT person_id FROM person p
                                          JOIN company c USING (company_id)
                                         WHERE c.primary_domain = 'oakhausmarketing.agency')),
                   'rule_fired keeps every reason; only the ledger picks one');

DELETE FROM suppression_list;


-- --------------------------------------------------------------------------
--  Person scope, and the expiry clock.
-- --------------------------------------------------------------------------

INSERT INTO suppression_list (suppression_id, reason, scope, person_id,
                              added_by, added_at)
SELECT norm.surrogate('suppression', 'test:legal:1'),
       'legal_hold', 'person', p.person_id, 'test fixture', config.as_of()
  FROM person p WHERE p.primary_email = 'a.abubakar@threadbarepartners.co';

SELECT test.expect('suppression_list', 'person scope hits exactly one human', 1,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'list:legal_hold'));

SELECT test.expect('suppression_list', 'person scope removes one from eligible', 722,
                   (SELECT count(*) FROM eligibility_ledger WHERE decision = 'eligible'));

SELECT test.expect('suppression_list', 'derived state reads asserted suppression as suppressed', 1,
                   (SELECT count(*) FROM person_state s
                     JOIN person p USING (person_id)
                    WHERE p.primary_email = 'a.abubakar@threadbarepartners.co'
                      AND s.state = 'suppressed'));

-- An expired assertion stops suppressing on its own, and it is measured
-- against as_of rather than now() — the same clock discipline as the recycle
-- windows. A lapsed partner agreement that keeps an account cold for a year
-- because nobody deleted a row is a silent, permanent loss of pipeline.
UPDATE suppression_list SET expires_at = config.as_of() - 1;

SELECT test.expect('suppression_list', 'an expired assertion stops firing', 0,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'list:legal_hold'));

SELECT test.expect('suppression_list', 'expiry reads as_of, not now()', 1,
                   (SELECT count(*) FROM suppression_list s
                     WHERE s.expires_at < current_date),
                   'the row is still in the past relative to real time; only as_of decides');

-- Same row, expiring tomorrow rather than yesterday: it fires again.
UPDATE suppression_list SET expires_at = config.as_of() + 1;

SELECT test.expect('suppression_list', 'an unexpired assertion fires again', 1,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'list:legal_hold'));

DELETE FROM suppression_list;


-- --------------------------------------------------------------------------
--  Restored. The exported artifacts and every suite after this one must see
--  the same database the run produced.
-- --------------------------------------------------------------------------

SELECT test.expect('suppression_list', 'fixtures removed', 0,
                   (SELECT count(*) FROM suppression_list));

SELECT test.expect('suppression_list', 'eligible restored', 723,
                   (SELECT count(*) FROM eligibility_ledger WHERE decision = 'eligible'));
