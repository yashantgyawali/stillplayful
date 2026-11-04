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
