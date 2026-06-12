alter table shorts_app.shorts
    add column if not exists episode_name text,
    add column if not exists episode_order int;

create index if not exists shorts_episode_name_order
on shorts_app.shorts (episode_name, episode_order, created_at desc);
