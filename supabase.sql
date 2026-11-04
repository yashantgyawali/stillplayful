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

-- email notification (migration: stillplayful_vote_email_trigger).
-- after each vote, posts the vote and running totals to the google apps script in notify/vote-email.gs,
-- which emails yashantgyawali@gmail.com. the url and shared secret live in private.stillplayful_settings,
-- a schema the public api can't reach. pg_net is async, so a failed email never blocks a vote.

create extension if not exists pg_net with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.stillplayful_settings (
  id int primary key default 1 check (id = 1),
  notify_url text not null,
  secret text not null
);

create or replace function private.notify_stillplayful_vote()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  s private.stillplayful_settings;
  totals jsonb;
begin
  select * into s from private.stillplayful_settings where id = 1;
  if s.notify_url is null then
    return new;
  end if;

  select coalesce(jsonb_object_agg(choice, n), '{}'::jsonb) into totals
  from (select choice, count(*) as n from public.stillplayful_votes group by choice) t;

  perform net.http_post(
    url := s.notify_url,
    body := jsonb_build_object('secret', s.secret, 'email', new.email, 'choice', new.choice, 'totals', totals),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );

  return new;
end;
$$;

revoke all on function private.notify_stillplayful_vote() from public, anon, authenticated;

drop trigger if exists stillplayful_vote_email on public.stillplayful_votes;
create trigger stillplayful_vote_email
  after insert on public.stillplayful_votes
  for each row execute function private.notify_stillplayful_vote();
