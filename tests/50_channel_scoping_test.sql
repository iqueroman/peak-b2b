-- tests/50_channel_scoping_test.sql
--
-- Channel scoping is the one decision in 04 whose consequences are invisible
-- on the default run: with a two-channel experiment, unsubscribe rejects
-- nobody. That could mean the rule works, or it could mean the rule is dead
-- code. This flips the experiment to email-only and checks it bites.
--
-- It also prices 04's stated assumption. 04 registers "a stricter counsel
-- reading would globalise all 29 unsubscribes" as an open question for
-- counsel; the difference between the two readings is measured here rather
-- than estimated.

-- Email-only experiment: everyone unsubscribed from email is now excluded
-- outright, and the LinkedIn-only unsubscribers stay eligible.
UPDATE experiment SET channels = ARRAY['email'] WHERE name = config.experiment();

SELECT test.expect('channel_scoping', 'email-only: unsubscribed now rejects', 16,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:unsubscribed'),
                   '21 unsubscribed from email; 5 are outranked by dnc or a company rule');

-- The rule that rejects nobody on the default run. With no LinkedIn step to
-- fall back to, an address-scoped bounce removes the person outright.
SELECT test.expect('channel_scoping', 'email-only: bounced now rejects', 54,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:bounced'));

SELECT test.expect('channel_scoping', 'email-only: nothing is withheld, only rejected', 0,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE decision = 'eligible' AND channels_withheld <> '{}'::jsonb));

SELECT test.expect('channel_scoping', 'email-only: eligible', 687,
                   (SELECT count(*) FROM eligibility_ledger WHERE decision = 'eligible'));

SELECT test.expect('channel_scoping', 'email-only: nobody is offered linkedin', 0,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE decision = 'eligible' AND 'linkedin' = ANY (channels)));

-- The rule 04 does not have. Without it these five would appear in
-- eligible.csv with a verdict and no address to send to.
SELECT test.expect('channel_scoping', 'email-only: unreachable people are rejected, not eligible', 5,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:unreachable_on_channel'));

SELECT test.expect('channel_scoping', 'email-only: no eligible person lacks an address', 0,
                   (SELECT count(*) FROM eligibility_ledger l
                     JOIN person p USING (person_id)
                    WHERE l.decision = 'eligible' AND p.primary_email IS NULL));

-- LinkedIn-only experiment: the mirror image. Bounces stop mattering entirely,
-- because a bounce kills an address and LinkedIn does not use one.
UPDATE experiment SET channels = ARRAY['linkedin'] WHERE name = config.experiment();

SELECT test.expect('channel_scoping', 'linkedin-only: bounces stop excluding anyone', 0,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:bounced'));

SELECT test.expect('channel_scoping', 'linkedin-only: email unsubscribers are reachable', 0,
                   (SELECT count(*) FROM eligibility_ledger l
                     JOIN person_history h USING (person_id)
                    WHERE l.rule_name = 'person:unsubscribed'
                      AND h.unsubscribed_channels = ARRAY['email']));

SELECT test.expect('channel_scoping', 'linkedin-only: linkedin unsubscribers are rejected', 7,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:unsubscribed'));

SELECT test.expect('channel_scoping', 'linkedin-only: eligible', 719,
                   (SELECT count(*) FROM eligibility_ledger WHERE decision = 'eligible'));

-- Restore, so the exported artifacts and every other suite see the real
-- experiment. A test that leaves the database changed is a test that makes the
-- next number a lie.
UPDATE experiment SET channels = ARRAY['email', 'linkedin'] WHERE name = config.experiment();

SELECT test.expect('channel_scoping', 'experiment restored to both channels', 723,
                   (SELECT count(*) FROM eligibility_ledger WHERE decision = 'eligible'));
