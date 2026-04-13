-- Videos bucket: public-read, up to 500MB per object (for longer shorts).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('shorts-videos', 'shorts-videos', true, 524288000, array['video/mp4'])
on conflict (id) do update set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Thumbnails bucket: public-read, up to 10MB per object.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('shorts-thumbnails', 'shorts-thumbnails', true, 10485760, array['image/png'])
on conflict (id) do update set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Frames bucket: public-read, up to 2MB per object (JPG).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('shorts-frames', 'shorts-frames', true, 2097152, array['image/jpeg'])
on conflict (id) do update set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Buckets are public-read in v1 so iOS can stream media without signed-URL infrastructure.
-- Mac uploads with service role; iOS never receives the service-role key.
