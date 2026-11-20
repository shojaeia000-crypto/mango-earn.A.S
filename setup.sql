-- MANGO EARN (Mode A) - paste ALL of this in Supabase > SQL Editor > Run.
-- Safe to run on top of the old setup (it only adds what is missing).
create extension if not exists pgcrypto with schema extensions;

create table if not exists players(
  id bigserial primary key, key text unique not null, name text not null, bale text unique not null,
  pw text not null, tok text not null default gen_random_uuid()::text,
  created bigint not null default (extract(epoch from now())*1000)::bigint,
  taps bigint not null default 0, lvl int not null default 0, prog int not null default 0,
  coins bigint not null default 0, bonus bigint not null default 0, followers bigint not null default 0,
  st jsonb not null default '{}', adm int not null default 0);
alter table players add column if not exists avatar text not null default '';
alter table players add column if not exists last_seen timestamptz;
alter table players add column if not exists daily date;

create table if not exists admin(name text primary key, pw text not null, tok text not null default gen_random_uuid()::text);
create table if not exists settings(id int primary key default 1,
  ev jsonb not null default '{"on":false,"from":"12:00","to":"16:00","pts":5}',
  msg jsonb not null default '{"id":0,"text":""}');
insert into settings(id) values(1) on conflict do nothing;
create table if not exists feedback(id bigserial primary key, pkey text not null, name text, bale text, txt text not null, created timestamptz not null default now());

alter table players enable row level security; alter table admin enable row level security;
alter table settings enable row level security; alter table feedback enable row level security;
revoke all on players, admin, settings, feedback from anon, authenticated;

-- ADMIN LOGIN: change the password here if you like (only inserted the first time)
insert into admin(name,pw) values('امیرمحمد', extensions.crypt('15679', extensions.gen_salt('bf',8))) on conflict (name) do nothing;

create or replace function te_n(v text, m numeric) returns bigint language sql immutable as $$
  select case when v ~ '^[0-9]+(\.[0-9]+)?$' then least(m, floor(v::numeric))::bigint end $$;

create or replace function te_lb() returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(t), '[]'::jsonb) from
   (select name, least(lvl+1,3) as lv, taps, coins, followers from players order by taps desc limit 50) t $$;

-- daily bonus / event / broadcast info for a player (Iran time)
create or replace function te_cfg(x players) returns jsonb language plpgsql security definer set search_path=public as $$
declare s settings; t timestamp := now() at time zone 'Asia/Tehran'; m int; f int; e int; act bool := false; lf int := 0;
begin
  select * into s from settings where id = 1;
  m := extract(hour from t)::int*60 + extract(minute from t)::int;
  if (s.ev->>'on')::boolean then
    f := split_part(s.ev->>'from',':',1)::int*60 + split_part(s.ev->>'from',':',2)::int;
    e := split_part(s.ev->>'to',':',1)::int*60 + split_part(s.ev->>'to',':',2)::int;
    if m >= f and m < e then act := true; lf := e*60 - (m*60 + extract(second from t)::int); end if;
  end if;
  return jsonb_build_object('daily', x.daily is distinct from t::date, 'amt', 200,
    'ev', jsonb_build_object('active', act, 'pts', coalesce((s.ev->>'pts')::int,5), 'left', lf), 'msg', s.msg);
end $$;
revoke execute on function te_cfg(players) from public, anon, authenticated;

create or replace function te(a jsonb) returns jsonb language plpgsql security definer set search_path=public, extensions as $$
declare act text := a->>'a'; x players; ad admin; k text; c jsonb; v_lvl int; t text;
        td date := (now() at time zone 'Asia/Tehran')::date;
begin
  if act = 'lb' then return jsonb_build_object('lb', te_lb()); end if;

  if act = 'signup' then
    k := lower(trim(coalesce(a->>'u','')));
    if k !~ '^[[:alnum:]_.-]{3,16}$' then raise exception 'Username: 3-16 letters or numbers'; end if;
    if length(coalesce(a->>'p','')) < 4 then raise exception 'Password must be at least 4 characters'; end if;
    if lower(trim(coalesce(a->>'b',''))) !~ '^[a-z][a-z0-9_]{4,31}$' then raise exception 'Enter your Bale ID in English (letters, numbers, _)'; end if;
    if exists(select 1 from admin where lower(name) = k) then raise exception 'Username already taken'; end if;
    begin
      insert into players(key,name,bale,pw,last_seen) values (k, trim(a->>'u'), lower(trim(a->>'b')), crypt(a->>'p', gen_salt('bf',8)), now()) returning * into x;
    exception when unique_violation then raise exception 'Username or Bale ID is already used'; end;
    return jsonb_build_object('t', x.tok, 'user', to_jsonb(x)-'pw'-'tok'-'id');
  end if;

  if act = 'login' then
    select * into ad from admin where name = trim(coalesce(a->>'u','')) and pw = crypt(coalesce(a->>'p',''), pw);
    if found then return jsonb_build_object('admin', true, 't', ad.tok); end if;
    select * into x from players where key = lower(trim(coalesce(a->>'u',''))) and pw = crypt(coalesce(a->>'p',''), pw);
    if not found then raise exception 'Wrong username or password'; end if;
    update players set last_seen = now() where id = x.id;
    return jsonb_build_object('t', x.tok, 'user', to_jsonb(x)-'pw'-'tok'-'id');
  end if;

  if act in ('sync','daily','avatar','fb') then
    select * into x from players where tok = a->>'t';
    if not found then raise exception 'auth'; end if;

    if act = 'sync' then
      update players set last_seen = now() where id = x.id;
      if (a->>'adm')::int is distinct from x.adm then   -- admin changed this account: admin wins
        return jsonb_build_object('over', true, 'user', to_jsonb(x)-'pw'-'tok'-'id', 'lb', te_lb(), 'cfg', te_cfg(x));
      end if;
      c := a->'u';
      if c is not null and jsonb_typeof(c) = 'object' then
        v_lvl := greatest(0, least(3, coalesce((c->>'lvl')::int, 0)));
        update players set
          taps  = greatest(0, least(1000000000, coalesce((c->>'taps')::bigint, 0))),
          coins = greatest(0, least(1000000000000, coalesce((c->>'coins')::bigint, 0))),
          bonus = greatest(0, least(1000000000, coalesce((c->>'bonus')::bigint, 0))),
          lvl = v_lvl,
          prog = case when v_lvl > 2 then 0 else greatest(0, least((array[99,399,499])[v_lvl+1], coalesce((c->>'prog')::int, 0))) end,
          st = case when length(coalesce(c->>'st','')) < 2000 then coalesce(c->'st','{}'::jsonb) else st end
        where id = x.id returning * into x;
      end if;
      return jsonb_build_object('user', to_jsonb(x)-'pw'-'tok'-'id'-'avatar', 'lb', te_lb(), 'cfg', te_cfg(x));
    end if;

    if act = 'daily' then      -- once per Iran calendar day; missed days are lost
      update players set daily = td where id = x.id and daily is distinct from td;
      if not found then raise exception 'Already claimed today'; end if;
      return jsonb_build_object('amt', 200);
    end if;

    if act = 'avatar' then
      t := coalesce(a->>'img','');
      if length(t) > 60000 or t !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$' then raise exception 'Bad image'; end if;
      update players set avatar = t where id = x.id; return '{}'::jsonb;
    end if;

    if act = 'fb' then
      t := trim(coalesce(a->>'text',''));
      if length(t) < 1 or length(t) > 500 then raise exception 'Write 1-500 characters'; end if;
      if exists(select 1 from feedback where pkey = x.key and created > now() - interval '30 seconds') then raise exception 'Please wait a moment'; end if;
      insert into feedback(pkey,name,bale,txt) values (x.key, x.name, x.bale, t); return '{}'::jsonb;
    end if;
  end if;

  if act in ('alist','aset','adel','astats','aev','amsg','afb','afbdel') then
    select * into ad from admin where tok = a->>'t';
    if not found then raise exception 'auth'; end if;

    if act = 'alist' then
      return jsonb_build_object('users', coalesce((select jsonb_agg(to_jsonb(p)-'pw'-'tok'-'id'-'avatar' order by p.taps desc) from players p), '[]'::jsonb));
    elsif act = 'adel' then
      delete from players where key = a->>'n'; return '{}'::jsonb;
    elsif act = 'astats' then
      return jsonb_build_object(
        'total', (select count(*) from players),
        'active', (select count(*) from players where (last_seen at time zone 'Asia/Tehran')::date = td),
        'today', (select count(*) from players where (to_timestamp(created/1000.0) at time zone 'Asia/Tehran')::date = td),
        'chart', (select jsonb_agg(jsonb_build_object('d', to_char(g.d,'MM-DD'),
                   'n', (select count(*) from players p where (to_timestamp(p.created/1000.0) at time zone 'Asia/Tehran')::date = g.d::date)) order by g.d)
                  from generate_series((td-6)::timestamp, td::timestamp, interval '1 day') g(d)),
        'ev', (select ev from settings where id = 1), 'msg', (select msg from settings where id = 1));
    elsif act = 'aev' then
      c := a->'ev';
      if coalesce(c->>'from','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(c->>'to','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Time must be HH:MM'; end if;
      if (c->>'from') >= (c->>'to') then raise exception 'End must be after start'; end if;
      update settings set ev = jsonb_build_object('on', coalesce((c->>'on')::boolean,false), 'from', c->>'from', 'to', c->>'to',
        'pts', greatest(0, least(1000, coalesce((c->>'pts')::int, 5)))) where id = 1;
      return '{}'::jsonb;
    elsif act = 'amsg' then
      update settings set msg = jsonb_build_object('id', coalesce((msg->>'id')::int,0)+1, 'text', left(trim(coalesce(a->>'text','')), 400)) where id = 1;
      return '{}'::jsonb;
    elsif act = 'afb' then
      return jsonb_build_object('items', coalesce((select jsonb_agg(jsonb_build_object('id',f.id,'name',f.name,'bale',f.bale,'txt',f.txt,'at',f.created) order by f.created desc)
                from (select * from feedback order by created desc limit 100) f), '[]'::jsonb));
    elsif act = 'afbdel' then
      delete from feedback where id = (a->>'id')::bigint; return '{}'::jsonb;
    else  -- aset
      c := a->'f';
      select * into x from players where key = a->>'n';
      if not found then raise exception 'No such user'; end if;
      update players set
        coins = coalesce(te_n(c->>'coins',1e12), coins), taps = coalesce(te_n(c->>'taps',1e9), taps),
        bonus = coalesce(te_n(c->>'bonus',1e9), bonus), followers = coalesce(te_n(c->>'followers',1e9), followers),
        lvl = coalesce(te_n(c->>'lvl',3), lvl), adm = adm + 1
      where id = x.id returning * into x;
      update players set prog = case when lvl > 2 then 0 else least(coalesce(te_n(c->>'prog',1e9), prog), (array[99,399,499])[lvl+1]) end where id = x.id;
      if length(coalesce(c->>'pw','')) >= 4 then
        update players set pw = crypt(c->>'pw', gen_salt('bf',8)), tok = gen_random_uuid()::text where id = x.id;
      end if;
      return '{}'::jsonb;
    end if;
  end if;
  raise exception 'bad action';
end $$;

grant execute on function te(jsonb), te_lb() to anon;
