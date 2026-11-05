-- already applied to the akabare-panipuri supabase project (migration: create_stillplayful_votes).
-- one row per email; the unique constraint is what enforces one vote per person.

create table if not exists public.stillplayful_votes (
  id bigint generated always as identity primary key,
  choice text not null constraint stillplayful_votes_choice_check check (choice in ('pendant', 'cap', 'socks', 'bracelet')),
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

-- instagram riddle (migrations: stillplayful_riddle_check, stillplayful_riddle_check_cleanup).
-- the email box on the page doubles as a code box. the page only sends the guess to
-- public.check_stillplayful_riddle; the answer (bcrypt hash only) and the prize text live in the
-- private schema, so neither appears in the page source or the public api. guesses are limited to
-- 5 a minute and 30 an hour per ip (cloudflare's cf-connecting-ip, which callers can't fake), plus a
-- global cap of 60 wrong guesses a minute so a botnet of many ips still can't out-guess the code.
-- the answer is deliberately not written here. to change the answer or the prize:
--   update private.stillplayful_riddle
--   set answer_hash = extensions.crypt('<new answer>', extensions.gen_salt('bf', 10)), prize = '<text>'
--   where id = 1;

create table if not exists private.stillplayful_riddle (
  id int primary key default 1 check (id = 1),
  answer_hash text not null,
  prize text not null
);

create table if not exists private.stillplayful_riddle_attempts (
  id bigint generated always as identity primary key,
  ip text not null,
  correct boolean not null,
  created_at timestamptz not null default now()
);

create index if not exists stillplayful_riddle_attempts_ip_time
  on private.stillplayful_riddle_attempts (ip, created_at);

create or replace function public.check_stillplayful_riddle(answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  caller_ip text := coalesce(
    headers ->> 'cf-connecting-ip',
    nullif(split_part(headers ->> 'x-forwarded-for', ',', 1), ''),
    'unknown'
  );
  guess text := regexp_replace(coalesce(answer, ''), '\D', '', 'g');
  last_minute int;
  last_hour int;
  global_minute int;
  r private.stillplayful_riddle;
  is_correct boolean;
begin
  -- per ip: 5 guesses a minute, 30 an hour, so scripting through 100 million codes is out of reach.
  select count(*) filter (where created_at > now() - interval '1 minute'), count(*)
  into last_minute, last_hour
  from private.stillplayful_riddle_attempts
  where ip = caller_ip and created_at > now() - interval '1 hour';

  -- global: at most 60 wrong guesses a minute from everyone, so a botnet of many ips still can't
  -- out-guess an 8-digit code. correct guesses never count toward this.
  select count(*) into global_minute
  from private.stillplayful_riddle_attempts
  where correct = false and created_at > now() - interval '1 minute';

  if last_minute >= 5 or last_hour >= 30 or global_minute >= 60 then
    return jsonb_build_object('ok', false, 'slow_down', true);
  end if;

  if length(guess) = 0 or length(guess) > 32 then
    return jsonb_build_object('ok', false);
  end if;

  select * into r from private.stillplayful_riddle where id = 1;
  is_correct := r.answer_hash = extensions.crypt(guess, r.answer_hash);

  insert into private.stillplayful_riddle_attempts (ip, correct) values (caller_ip, is_correct);

  if is_correct then
    return jsonb_build_object('ok', true, 'prize', r.prize);
  end if;
  return jsonb_build_object('ok', false);
end;
$$;

revoke all on function public.check_stillplayful_riddle(text) from public, authenticated;
grant execute on function public.check_stillplayful_riddle(text) to anon;
