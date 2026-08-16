-- Nobody has ever had a referral code.
--
-- Verified live 2026-08-16: `select referral_code from profiles` returns NULL
-- for EVERY row (all 9 profiles — fans, partner and admin alike), so the
-- "Invite & earn" screen has always rendered "—" instead of a code and the
-- referral program has been unusable end-to-end.
--
-- Cause: legacy's get_fan_referral_data() GENERATED a code on first read when
-- the column was null, then persisted it. The live rewrite
-- (referrals.module.ts myReferralData) only SELECTs the column — the
-- generate-on-demand half was never carried over, and nothing else in the
-- schema assigns one (no default, no trigger).
--
-- Fix: assign at insert via trigger (so every new signup gets one), and
-- backfill every existing row. Format matches legacy's — 8 uppercase hex
-- chars — so any code already shared out in the wild stays the same shape.
-- profiles.referral_code carries a UNIQUE constraint
-- (profiles_referral_code_key), hence the collision retry.

create or replace function public.generate_referral_code(p_profile_id uuid)
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_code text;
  v_tries int := 0;
begin
  loop
    -- clock_timestamp(), not now(): now() is fixed for the whole transaction,
    -- so a backfill loop would derive the same input twice for two rows
    -- retried in the same statement.
    v_code := upper(substring(md5(p_profile_id::text || clock_timestamp()::text) from 1 for 8));
    exit when not exists (select 1 from public.profiles where referral_code = v_code);
    v_tries := v_tries + 1;
    if v_tries > 10 then
      raise exception 'could not generate a unique referral code for %', p_profile_id;
    end if;
  end loop;
  return v_code;
end;
$$;

-- SECURITY DEFINER above is load-bearing: the uniqueness probe must see EVERY
-- profile row. Under RLS a fan inserting their own profile can only see their
-- own, so the check would be blind to other users' codes and the UNIQUE
-- constraint would raise instead.

create or replace function public.set_referral_code_on_insert()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if new.referral_code is null then
    new.referral_code := public.generate_referral_code(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_profiles_referral_code on public.profiles;
create trigger trg_profiles_referral_code
  before insert on public.profiles
  for each row execute function public.set_referral_code_on_insert();

-- Backfill every existing profile.
do $$
declare r record;
begin
  for r in select id from public.profiles where referral_code is null loop
    update public.profiles set referral_code = public.generate_referral_code(r.id) where id = r.id;
  end loop;
end $$;
