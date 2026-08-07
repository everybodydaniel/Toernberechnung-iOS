CREATE TABLE IF NOT EXISTS skipper_profiles (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    boat_type TEXT NOT NULL DEFAULT 'Unbekannt',
    profile_image_url TEXT,
    home_harbour TEXT,
    bio TEXT,
    follower_count INTEGER NOT NULL DEFAULT 0,
    following_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS posts (
    id TEXT PRIMARY KEY,
    skipper_id TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    text TEXT NOT NULL DEFAULT '',
    image_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT posts_text_or_image CHECK (length(trim(text)) > 0 OR image_url IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS post_likes (
    post_id TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    skipper_id TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (post_id, skipper_id)
);

CREATE TABLE IF NOT EXISTS comments (
    id TEXT PRIMARY KEY,
    post_id TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    skipper_id TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS profile_follows (
    follower_id TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    followed_id TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (follower_id, followed_id),
    CONSTRAINT profile_follows_no_self_follow CHECK (follower_id <> followed_id)
);

CREATE INDEX IF NOT EXISTS posts_created_at_idx ON posts (created_at DESC);
CREATE INDEX IF NOT EXISTS posts_skipper_created_at_idx ON posts (skipper_id, created_at DESC);
CREATE INDEX IF NOT EXISTS comments_post_created_at_idx ON comments (post_id, created_at ASC);
CREATE INDEX IF NOT EXISTS post_likes_skipper_idx ON post_likes (skipper_id);
CREATE INDEX IF NOT EXISTS profile_follows_followed_idx ON profile_follows (followed_id);

CREATE TABLE IF NOT EXISTS crewspace_conversations (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    info TEXT NOT NULL DEFAULT '',
    kind TEXT NOT NULL CHECK (kind IN ('direct', 'group')),
    direct_key TEXT UNIQUE,
    direct_user_low TEXT,
    direct_user_high TEXT,
    created_by TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE crewspace_conversations ADD COLUMN IF NOT EXISTS info TEXT NOT NULL DEFAULT '';
ALTER TABLE crewspace_conversations ADD COLUMN IF NOT EXISTS direct_user_low TEXT;
ALTER TABLE crewspace_conversations ADD COLUMN IF NOT EXISTS direct_user_high TEXT;

CREATE TABLE IF NOT EXISTS crewspace_members (
    conversation_id TEXT NOT NULL REFERENCES crewspace_conversations(id) ON DELETE CASCADE,
    skipper_id TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')),
    crew_role TEXT NOT NULL DEFAULT 'Crew',
    is_on_board BOOLEAN NOT NULL DEFAULT FALSE,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_read_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    hidden_at TIMESTAMPTZ,
    PRIMARY KEY (conversation_id, skipper_id)
);

ALTER TABLE crewspace_members ADD COLUMN IF NOT EXISTS hidden_at TIMESTAMPTZ;
ALTER TABLE crewspace_members ADD COLUMN IF NOT EXISTS crew_role TEXT NOT NULL DEFAULT 'Crew';
ALTER TABLE crewspace_members ADD COLUMN IF NOT EXISTS is_on_board BOOLEAN NOT NULL DEFAULT FALSE;

CREATE OR REPLACE FUNCTION crewspace_sync_direct_participants()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    affected_conversation_id TEXT;
BEGIN
    affected_conversation_id := CASE
        WHEN TG_OP = 'DELETE' THEN OLD.conversation_id
        ELSE NEW.conversation_id
    END;

    UPDATE crewspace_conversations conversation
    SET direct_user_low = CASE
            WHEN participants.member_count = 2 THEN participants.direct_user_low
            WHEN TG_OP = 'INSERT' AND participants.member_count = 1
                THEN conversation.direct_user_low
            ELSE NULL
        END,
        direct_user_high = CASE
            WHEN participants.member_count = 2 THEN participants.direct_user_high
            WHEN TG_OP = 'INSERT' AND participants.member_count = 1
                THEN conversation.direct_user_high
            ELSE NULL
        END
    FROM (
        SELECT
            count(*) AS member_count,
            CASE WHEN count(*) = 2 THEN min(skipper_id) ELSE NULL END AS direct_user_low,
            CASE WHEN count(*) = 2 THEN max(skipper_id) ELSE NULL END AS direct_user_high
        FROM crewspace_members
        WHERE conversation_id = affected_conversation_id
    ) participants
    WHERE conversation.id = affected_conversation_id
      AND conversation.kind = 'direct';

    RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS crewspace_sync_direct_participants_trigger ON crewspace_members;
CREATE TRIGGER crewspace_sync_direct_participants_trigger
AFTER INSERT OR UPDATE OR DELETE ON crewspace_members
FOR EACH ROW EXECUTE FUNCTION crewspace_sync_direct_participants();

CREATE TABLE IF NOT EXISTS crewspace_messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES crewspace_conversations(id) ON DELETE CASCADE,
    sender_id TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    client_message_id TEXT NOT NULL,
    text TEXT NOT NULL DEFAULT '',
    media_url TEXT,
    media_type TEXT CHECK (media_type IN ('image', 'audio')),
    media_duration_seconds DOUBLE PRECISION,
    poll_id TEXT,
    event_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE crewspace_messages ADD COLUMN IF NOT EXISTS media_url TEXT;
ALTER TABLE crewspace_messages ADD COLUMN IF NOT EXISTS media_type TEXT;
ALTER TABLE crewspace_messages ADD COLUMN IF NOT EXISTS media_duration_seconds DOUBLE PRECISION;
ALTER TABLE crewspace_messages ADD COLUMN IF NOT EXISTS poll_id TEXT;
ALTER TABLE crewspace_messages ADD COLUMN IF NOT EXISTS event_id TEXT;
ALTER TABLE crewspace_messages ADD COLUMN IF NOT EXISTS client_message_id TEXT;
UPDATE crewspace_messages SET client_message_id = id WHERE client_message_id IS NULL;
ALTER TABLE crewspace_messages ALTER COLUMN client_message_id SET NOT NULL;
ALTER TABLE crewspace_messages DROP CONSTRAINT IF EXISTS crewspace_messages_text_check;
ALTER TABLE crewspace_messages DROP CONSTRAINT IF EXISTS crewspace_messages_content_check;
ALTER TABLE crewspace_messages ADD CONSTRAINT crewspace_messages_content_check
    CHECK (length(trim(text)) > 0 OR media_url IS NOT NULL OR poll_id IS NOT NULL OR event_id IS NOT NULL);
ALTER TABLE crewspace_messages DROP CONSTRAINT IF EXISTS crewspace_messages_media_type_check;
ALTER TABLE crewspace_messages ADD CONSTRAINT crewspace_messages_media_type_check
    CHECK (media_type IS NULL OR media_type IN ('image', 'audio'));

CREATE TABLE IF NOT EXISTS crewspace_events (
    id TEXT PRIMARY KEY,
    conversation_id TEXT REFERENCES crewspace_conversations(id) ON DELETE CASCADE,
    creator_id TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
    starts_at TIMESTAMPTZ NOT NULL,
    ends_at TIMESTAMPTZ NOT NULL,
    location TEXT,
    notes TEXT,
    attachment_url TEXT,
    attachment_name TEXT,
    attachment_content_type TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (ends_at >= starts_at)
);

ALTER TABLE crewspace_events ALTER COLUMN conversation_id DROP NOT NULL;
ALTER TABLE crewspace_events ADD COLUMN IF NOT EXISTS attachment_url TEXT;
ALTER TABLE crewspace_events ADD COLUMN IF NOT EXISTS attachment_name TEXT;
ALTER TABLE crewspace_events ADD COLUMN IF NOT EXISTS attachment_content_type TEXT;

CREATE TABLE IF NOT EXISTS crewspace_polls (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES crewspace_conversations(id) ON DELETE CASCADE,
    creator_id TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    question TEXT NOT NULL CHECK (length(trim(question)) > 0),
    allows_multiple BOOLEAN NOT NULL DEFAULT false,
    closes_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS crewspace_poll_options (
    id TEXT PRIMARY KEY,
    poll_id TEXT NOT NULL REFERENCES crewspace_polls(id) ON DELETE CASCADE,
    label TEXT NOT NULL CHECK (length(trim(label)) > 0),
    position INTEGER NOT NULL,
    UNIQUE (poll_id, position)
);

CREATE TABLE IF NOT EXISTS crewspace_poll_votes (
    poll_id TEXT NOT NULL REFERENCES crewspace_polls(id) ON DELETE CASCADE,
    option_id TEXT NOT NULL REFERENCES crewspace_poll_options(id) ON DELETE CASCADE,
    skipper_id TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (poll_id, option_id, skipper_id)
);

ALTER TABLE crewspace_messages DROP CONSTRAINT IF EXISTS crewspace_messages_poll_id_fkey;
ALTER TABLE crewspace_messages ADD CONSTRAINT crewspace_messages_poll_id_fkey
    FOREIGN KEY (poll_id) REFERENCES crewspace_polls(id) ON DELETE CASCADE;

ALTER TABLE crewspace_messages DROP CONSTRAINT IF EXISTS crewspace_messages_event_id_fkey;
ALTER TABLE crewspace_messages ADD CONSTRAINT crewspace_messages_event_id_fkey
    FOREIGN KEY (event_id) REFERENCES crewspace_events(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS crewspace_members_skipper_idx ON crewspace_members (skipper_id, conversation_id);
CREATE INDEX IF NOT EXISTS crewspace_messages_conversation_idx ON crewspace_messages (conversation_id, created_at ASC);
CREATE INDEX IF NOT EXISTS crewspace_messages_cursor_idx
    ON crewspace_messages (conversation_id, created_at ASC, id ASC);
CREATE UNIQUE INDEX IF NOT EXISTS crewspace_messages_client_id_idx
    ON crewspace_messages (conversation_id, sender_id, client_message_id);
CREATE INDEX IF NOT EXISTS crewspace_events_conversation_idx ON crewspace_events (conversation_id, starts_at ASC);
CREATE INDEX IF NOT EXISTS crewspace_polls_conversation_idx ON crewspace_polls (conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS crewspace_poll_votes_poll_idx ON crewspace_poll_votes (poll_id, option_id);

UPDATE crewspace_conversations conversation
SET direct_user_low = members.direct_user_low,
    direct_user_high = members.direct_user_high
FROM (
    SELECT conversation_id,
           min(skipper_id) AS direct_user_low,
           max(skipper_id) AS direct_user_high
    FROM crewspace_members
    GROUP BY conversation_id
    HAVING count(*) = 2
) members
WHERE conversation.id = members.conversation_id
  AND conversation.kind = 'direct'
  AND (conversation.direct_user_low IS NULL OR conversation.direct_user_high IS NULL);

CREATE UNIQUE INDEX IF NOT EXISTS crewspace_direct_participants_idx
    ON crewspace_conversations (direct_user_low, direct_user_high)
    WHERE kind = 'direct';

CREATE TABLE IF NOT EXISTS crewspace_blocks (
    blocker_uid TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    blocked_uid TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker_uid, blocked_uid),
    CHECK (blocker_uid <> blocked_uid)
);

CREATE INDEX IF NOT EXISTS crewspace_blocks_blocked_idx
    ON crewspace_blocks (blocked_uid, blocker_uid);

CREATE OR REPLACE FUNCTION crewspace_prepare_message_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    conversation_kind TEXT;
    peer_uid TEXT;
BEGIN
    SELECT conversation.kind,
           (
               SELECT member.skipper_id
               FROM crewspace_members member
               WHERE member.conversation_id = conversation.id
                 AND member.skipper_id <> NEW.sender_id
               ORDER BY member.skipper_id
               LIMIT 1
           )
    INTO conversation_kind, peer_uid
    FROM crewspace_conversations conversation
    WHERE conversation.id = NEW.conversation_id;

    IF conversation_kind = 'direct' AND peer_uid IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(
            hashtext(LEAST(NEW.sender_id, peer_uid)),
            hashtext(GREATEST(NEW.sender_id, peer_uid))
        );
    END IF;

    PERFORM 1
    FROM crewspace_conversations
    WHERE id = NEW.conversation_id
    FOR UPDATE;

    IF conversation_kind = 'direct' AND EXISTS (
        SELECT 1
        FROM crewspace_blocks block
        WHERE (block.blocker_uid = NEW.sender_id AND block.blocked_uid = peer_uid)
           OR (block.blocker_uid = peer_uid AND block.blocked_uid = NEW.sender_id)
    ) THEN
        RAISE EXCEPTION 'chat_unavailable' USING ERRCODE = 'P0001';
    END IF;

    SELECT GREATEST(
        clock_timestamp(),
        COALESCE(max(message.created_at) + interval '1 microsecond', '-infinity'::timestamptz)
    )
    INTO NEW.created_at
    FROM crewspace_messages message
    WHERE message.conversation_id = NEW.conversation_id;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS crewspace_prepare_message_insert_trigger ON crewspace_messages;
CREATE TRIGGER crewspace_prepare_message_insert_trigger
BEFORE INSERT ON crewspace_messages
FOR EACH ROW EXECUTE FUNCTION crewspace_prepare_message_insert();

CREATE TABLE IF NOT EXISTS push_installations (
    installation_id TEXT PRIMARY KEY,
    skipper_id TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    platform TEXT NOT NULL CHECK (platform IN ('android', 'ios')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS push_installations_skipper_idx
    ON push_installations (skipper_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS push_outbox (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES crewspace_conversations(id) ON DELETE CASCADE,
    message_id TEXT NOT NULL REFERENCES crewspace_messages(id) ON DELETE CASCADE,
    recipient_uid TEXT NOT NULL REFERENCES skipper_profiles(id) ON DELETE CASCADE,
    sender_name TEXT NOT NULL,
    message_type TEXT NOT NULL CHECK (message_type IN ('text', 'image', 'audio', 'poll', 'event')),
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ,
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (message_id, recipient_uid)
);

CREATE INDEX IF NOT EXISTS push_outbox_pending_idx
    ON push_outbox (next_attempt_at, created_at)
    WHERE processed_at IS NULL;

CREATE TABLE IF NOT EXISTS maritime_notices (
    id TEXT PRIMARY KEY,
    bfs_number TEXT NOT NULL,
    is_temporary BOOLEAN NOT NULL DEFAULT false,
    publisher TEXT NOT NULL,
    title TEXT NOT NULL,
    region_path TEXT NOT NULL,
    location TEXT,
    body TEXT NOT NULL,
    published_at TIMESTAMPTZ,
    valid_from TIMESTAMPTZ,
    valid_until TIMESTAMPTZ,
    publication_state TEXT NOT NULL CHECK (publication_state IN ('current', 'updated', 'revoked', 'expired')),
    revision INTEGER NOT NULL CHECK (revision > 0),
    source_url TEXT,
    chart_references JSONB NOT NULL DEFAULT '[]'::jsonb,
    coordinates JSONB NOT NULL DEFAULT '[]'::jsonb,
    previous_notices JSONB NOT NULL DEFAULT '[]'::jsonb,
    parse_status TEXT NOT NULL CHECK (parse_status IN ('parsed', 'partial', 'failed')),
    content_hash TEXT NOT NULL,
    message_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS maritime_notice_revisions (
    notice_id TEXT NOT NULL REFERENCES maritime_notices(id) ON DELETE CASCADE,
    revision INTEGER NOT NULL,
    body TEXT NOT NULL,
    publication_state TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    message_id TEXT NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (notice_id, revision),
    UNIQUE (message_id)
);

CREATE TABLE IF NOT EXISTS elwis_ingestion_log (
    message_id TEXT PRIMARY KEY,
    notice_id TEXT,
    status TEXT NOT NULL,
    detail TEXT,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS elwis_sync_state (
    singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK (singleton),
    last_checked_at TIMESTAMPTZ,
    last_success_at TIMESTAMPTZ,
    last_error TEXT
);

INSERT INTO elwis_sync_state (singleton)
VALUES (true)
ON CONFLICT (singleton) DO NOTHING;

CREATE INDEX IF NOT EXISTS maritime_notices_updated_idx ON maritime_notices (updated_at DESC);
CREATE INDEX IF NOT EXISTS maritime_notices_state_idx ON maritime_notices (publication_state, valid_until, updated_at DESC);
