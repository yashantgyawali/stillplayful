-- already applied to the akabare-panipuri supabase project (migration: create_stillplayful_votes).
-- one row per email; the unique constraint is what enforces one vote per person.

create table if not exists public.stillplayful_votes (
  id bigint generated always as identity primary key,
  choice text not null check (choice in ('pendant', 'cap', 'tote', 'socks', 'bracelet')),
  email text not null unique check (email = lower(email) and char_length(email) <= 254),
  created_at timestamptz not null default now()
);

alter table public.stillplayful_votes enable row level security;

-- visitors can cast a vote but cannot read anyone's votes or emails.
create policy "anyone can vote"
  on public.stillplayful_votes for insert
  to anon
  with check (true);

-- tally, for you (run in the sql editor):
-- select choice, count(*) from public.stillplayful_votes group by choice order by count(*) desc;

-- email notification.
-- after each vote, a trigger posts the vote and running totals to formsubmit.co, which emails them on.
-- the formsubmit url (it contains the destination email) lives in private.stillplayful_settings,
-- a schema the public api can't reach, so it stays out of this public repo.
-- pg_net is async, so a slow or failed email never blocks a vote.
-- applied as migrations: stillplayful_vote_email_trigger, stillplayful_vote_email_formsubmit,
-- stillplayful_vote_email_timeout_domain, stillplayful_vote_email_drop_tote. to point it somewhere else:
--   update private.stillplayful_settings set notify_url = '<url>' where id = 1;

create extension if not exists pg_net with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.stillplayful_settings (
  id int primary key default 1 check (id = 1),
  notify_url text not null
);

create or replace function private.notify_stillplayful_vote()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  s private.stillplayful_settings;
  names constant jsonb := '{"pendant": "a pendant", "cap": "a cap", "tote": "a tote bag", "socks": "socks", "bracelet": "a bracelet"}';
  total bigint;
  totals text;
begin
  select * into s from private.stillplayful_settings where id = 1;
  if s.notify_url is null then
    return new;
  end if;

  select count(*) into total from public.stillplayful_votes;

  select string_agg(o.name || ': ' || coalesce(v.n, 0), E'\n' order by coalesce(v.n, 0) desc, o.ord)
  into totals
  from (values ('pendant', 'a pendant', 1), ('cap', 'a cap', 2), ('socks', 'socks', 4), ('bracelet', 'a bracelet', 5)) as o(choice, name, ord)
  left join (select choice, count(*) as n from public.stillplayful_votes group by choice) v using (choice);

  -- jsonb sorts keys by length, so the email lists vote, email, totals in that order.
  -- formsubmit is slow to answer, so allow 30s instead of pg_net's 5s default.
  perform net.http_post(
    url := s.notify_url,
    body := jsonb_build_object(
      '_subject', 'still playful: a vote for ' || (names ->> new.choice),
      '_template', 'box',
      '_captcha', 'false',
      'vote', names ->> new.choice,
      'email', new.email,
      'totals', total || ' votes so far' || E'\n' || totals
    ),
    headers := '{"Content-Type": "application/json", "Accept": "application/json", "Referer": "https://stillplayful.com/", "Origin": "https://stillplayful.com"}'::jsonb,
    timeout_milliseconds := 30000
  );

  return new;
end;
$$;

revoke all on function private.notify_stillplayful_vote() from public, anon, authenticated;

drop trigger if exists stillplayful_vote_email on public.stillplayful_votes;
create trigger stillplayful_vote_email
  after insert on public.stillplayful_votes
  for each row execute function private.notify_stillplayful_vote();
