--
-- PostgreSQL database dump
--

\restrict cpwDPyEt8gjthweZPPqGfgrbAnxoE3cnUUkbB2BxFNWfJTalb8dVmO2tyTfnVMY

-- Dumped from database version 16.10 (Homebrew)
-- Dumped by pg_dump version 16.10 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: oban_job_state; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.oban_job_state AS ENUM (
    'available',
    'suspended',
    'scheduled',
    'executing',
    'retryable',
    'completed',
    'discarded',
    'cancelled'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agent_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_runs (
    id uuid NOT NULL,
    document_id uuid,
    triggered_by_action_id uuid,
    status character varying(255) DEFAULT 'running'::character varying NOT NULL,
    turn_index integer DEFAULT 0 NOT NULL,
    previous_response_id character varying(255),
    message text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    owner_id uuid,
    chat_thread_id uuid,
    started_at timestamp(0) without time zone,
    completed_at timestamp(0) without time zone,
    error jsonb,
    model character varying(255),
    tools_enabled character varying(255)[] DEFAULT ARRAY[]::character varying[]
);


--
-- Name: blob_refs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.blob_refs (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    bucket character varying(255) NOT NULL,
    object_key character varying(255) NOT NULL,
    mime_type character varying(255),
    size_bytes integer,
    sha256 character varying(255),
    kind character varying(255) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.changes (
    id uuid NOT NULL,
    document_id uuid NOT NULL,
    command_kind character varying(255) NOT NULL,
    actor_type character varying(255) NOT NULL,
    actor_id uuid,
    base_revision integer,
    result_revision integer NOT NULL,
    idempotency_key character varying(255),
    payload jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    marks jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    message text,
    affected_refs jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    preimage jsonb,
    inverse jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    chat_thread_id uuid,
    source_document_id uuid,
    source_claim_id uuid,
    agent_run_id uuid,
    field_path character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    op character varying(255)
);


--
-- Name: chat_threads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_threads (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    document_id uuid,
    title text,
    messages jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    last_message_at timestamp(0) without time zone,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: document_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_types (
    id uuid NOT NULL,
    key character varying(255) NOT NULL,
    family character varying(255) DEFAULT 'other'::character varying NOT NULL,
    name_en character varying(255) NOT NULL,
    name_ko character varying(255),
    version character varying(255) DEFAULT 'legacy'::character varying NOT NULL,
    source character varying(255) DEFAULT 'custom'::character varying NOT NULL,
    source_url text,
    template_hwp_path text,
    template_hwpx_path text,
    spec jsonb DEFAULT '{}'::jsonb NOT NULL,
    default_matching_book jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documents (
    id uuid NOT NULL,
    title character varying(255) NOT NULL,
    type_key character varying(255),
    status character varying(255) DEFAULT 'draft'::character varying NOT NULL,
    parent_document_id uuid,
    variant_of_change_id uuid,
    latest_revision integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    state_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    current_revision integer DEFAULT 0 NOT NULL,
    owner_id uuid NOT NULL,
    document_type_id uuid
);


--
-- Name: evidence_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evidence_snapshots (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    chat_thread_id uuid,
    document_id uuid,
    source_document_id uuid,
    provider character varying(255) NOT NULL,
    query jsonb DEFAULT '{}'::jsonb NOT NULL,
    result jsonb DEFAULT '{}'::jsonb NOT NULL,
    result_hash character varying(255) NOT NULL,
    captured_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: exports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exports (
    id uuid NOT NULL,
    document_id uuid NOT NULL,
    requester_id uuid,
    format character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'queued'::character varying NOT NULL,
    progress integer DEFAULT 0 NOT NULL,
    key character varying(255),
    download_url character varying(255),
    content_type character varying(255),
    byte_size integer,
    error jsonb DEFAULT '{}'::jsonb,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: field_lineages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.field_lineages (
    id uuid NOT NULL,
    document_id uuid NOT NULL,
    field_id character varying(255) NOT NULL,
    source_document_id uuid,
    source_field_id character varying(255),
    strategy character varying(255) NOT NULL,
    justification text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: leases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.leases (
    document_id uuid NOT NULL,
    owner_ref text NOT NULL,
    fencing_token bigint NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


--
-- Name: leases_fencing_token_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.leases_fencing_token_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: leases_fencing_token_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.leases_fencing_token_seq OWNED BY public.leases.fencing_token;


--
-- Name: marks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.marks (
    id uuid NOT NULL,
    document_id uuid NOT NULL,
    evidence_snapshot_id uuid NOT NULL,
    field_path character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    change_id uuid,
    type character varying(255) DEFAULT 'evidence'::character varying NOT NULL,
    status character varying(255) DEFAULT 'attached'::character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: matters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.matters (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    tenant_id uuid,
    owner_id uuid NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: oban_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oban_jobs (
    id bigint NOT NULL,
    state public.oban_job_state DEFAULT 'available'::public.oban_job_state NOT NULL,
    queue text DEFAULT 'default'::text NOT NULL,
    worker text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    errors jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 20 NOT NULL,
    inserted_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    scheduled_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    attempted_at timestamp without time zone,
    completed_at timestamp without time zone,
    attempted_by text[],
    discarded_at timestamp without time zone,
    priority integer DEFAULT 0 NOT NULL,
    tags text[] DEFAULT ARRAY[]::text[],
    meta jsonb DEFAULT '{}'::jsonb,
    cancelled_at timestamp without time zone,
    CONSTRAINT attempt_range CHECK (((attempt >= 0) AND (attempt <= max_attempts))),
    CONSTRAINT positive_max_attempts CHECK ((max_attempts > 0)),
    CONSTRAINT queue_length CHECK (((char_length(queue) > 0) AND (char_length(queue) < 128))),
    CONSTRAINT worker_length CHECK (((char_length(worker) > 0) AND (char_length(worker) < 128)))
);


--
-- Name: TABLE oban_jobs; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.oban_jobs IS '14';


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oban_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oban_jobs_id_seq OWNED BY public.oban_jobs.id;


--
-- Name: oban_peers; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.oban_peers (
    name text NOT NULL,
    node text NOT NULL,
    started_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL
);


--
-- Name: revoke_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.revoke_requests (
    id uuid NOT NULL,
    document_id uuid NOT NULL,
    target_change_id uuid NOT NULL,
    overlap_changes uuid[] DEFAULT ARRAY[]::uuid[] NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    resolution_change_id uuid,
    requester_id uuid,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: slack_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_tokens (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    tenant_id uuid,
    slack_team_id character varying(255) NOT NULL,
    slack_user_id character varying(255) NOT NULL,
    access_token bytea NOT NULL,
    scopes character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    expires_at timestamp(0) without time zone,
    raw_response jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.snapshots (
    document_id uuid NOT NULL,
    revision integer NOT NULL,
    projection jsonb NOT NULL,
    r2_key character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: source_claims; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.source_claims (
    id uuid NOT NULL,
    source_document_id uuid NOT NULL,
    region_id character varying(255),
    proposed_kind character varying(255),
    proposed_value text,
    proposed_structured jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying(255) DEFAULT 'proposed'::character varying NOT NULL,
    user_value text,
    user_structured jsonb DEFAULT '{}'::jsonb NOT NULL,
    linked_document_id uuid,
    linked_node_id character varying(255),
    agent_run_id uuid,
    confidence numeric,
    rationale text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: source_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.source_documents (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    chat_thread_id uuid,
    document_id uuid,
    blob_ref_id uuid NOT NULL,
    mime_type character varying(255),
    original_filename character varying(255),
    parser_snapshot_ref character varying(255),
    regions jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    status character varying(255) DEFAULT 'uploaded'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: tool_calls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tool_calls (
    id uuid NOT NULL,
    agent_run_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    arguments jsonb DEFAULT '{}'::jsonb NOT NULL,
    result jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    started_at timestamp(0) without time zone,
    completed_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    email public.citext NOT NULL,
    hashed_password character varying(255),
    confirmed_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: users_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users_tokens (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    token bytea NOT NULL,
    context character varying(255) NOT NULL,
    sent_to character varying(255),
    authenticated_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: leases fencing_token; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leases ALTER COLUMN fencing_token SET DEFAULT nextval('public.leases_fencing_token_seq'::regclass);


--
-- Name: oban_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);


--
-- Name: agent_runs agent_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_runs
    ADD CONSTRAINT agent_runs_pkey PRIMARY KEY (id);


--
-- Name: blob_refs blob_refs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.blob_refs
    ADD CONSTRAINT blob_refs_pkey PRIMARY KEY (id);


--
-- Name: changes changes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.changes
    ADD CONSTRAINT changes_pkey PRIMARY KEY (id);


--
-- Name: chat_threads chat_threads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_threads
    ADD CONSTRAINT chat_threads_pkey PRIMARY KEY (id);


--
-- Name: document_types document_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_pkey PRIMARY KEY (id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: evidence_snapshots evidence_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence_snapshots
    ADD CONSTRAINT evidence_snapshots_pkey PRIMARY KEY (id);


--
-- Name: exports exports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exports
    ADD CONSTRAINT exports_pkey PRIMARY KEY (id);


--
-- Name: field_lineages field_lineages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.field_lineages
    ADD CONSTRAINT field_lineages_pkey PRIMARY KEY (id);


--
-- Name: leases leases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leases
    ADD CONSTRAINT leases_pkey PRIMARY KEY (document_id);


--
-- Name: marks marks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marks
    ADD CONSTRAINT marks_pkey PRIMARY KEY (id);


--
-- Name: matters matters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.matters
    ADD CONSTRAINT matters_pkey PRIMARY KEY (id);


--
-- Name: oban_jobs non_negative_priority; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.oban_jobs
    ADD CONSTRAINT non_negative_priority CHECK ((priority >= 0)) NOT VALID;


--
-- Name: oban_jobs oban_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs
    ADD CONSTRAINT oban_jobs_pkey PRIMARY KEY (id);


--
-- Name: oban_peers oban_peers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_peers
    ADD CONSTRAINT oban_peers_pkey PRIMARY KEY (name);


--
-- Name: revoke_requests revoke_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.revoke_requests
    ADD CONSTRAINT revoke_requests_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: slack_tokens slack_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_tokens
    ADD CONSTRAINT slack_tokens_pkey PRIMARY KEY (id);


--
-- Name: snapshots snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.snapshots
    ADD CONSTRAINT snapshots_pkey PRIMARY KEY (document_id, revision);


--
-- Name: source_claims source_claims_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_claims
    ADD CONSTRAINT source_claims_pkey PRIMARY KEY (id);


--
-- Name: source_documents source_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_documents
    ADD CONSTRAINT source_documents_pkey PRIMARY KEY (id);


--
-- Name: tool_calls tool_calls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tool_calls
    ADD CONSTRAINT tool_calls_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users_tokens users_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_pkey PRIMARY KEY (id);


--
-- Name: agent_runs_chat_thread_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_runs_chat_thread_id_index ON public.agent_runs USING btree (chat_thread_id);


--
-- Name: agent_runs_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_runs_document_id_index ON public.agent_runs USING btree (document_id);


--
-- Name: agent_runs_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_runs_status_index ON public.agent_runs USING btree (status);


--
-- Name: blob_refs_bucket_object_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX blob_refs_bucket_object_key_index ON public.blob_refs USING btree (bucket, object_key);


--
-- Name: blob_refs_owner_id_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX blob_refs_owner_id_kind_index ON public.blob_refs USING btree (owner_id, kind);


--
-- Name: changes_agent_run_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX changes_agent_run_id_index ON public.changes USING btree (agent_run_id);


--
-- Name: changes_chat_thread_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX changes_chat_thread_id_index ON public.changes USING btree (chat_thread_id);


--
-- Name: changes_document_id_idempotency_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX changes_document_id_idempotency_key_index ON public.changes USING btree (document_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: changes_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX changes_document_id_index ON public.changes USING btree (document_id);


--
-- Name: changes_document_id_result_revision_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX changes_document_id_result_revision_index ON public.changes USING btree (document_id, result_revision);


--
-- Name: changes_source_claim_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX changes_source_claim_id_index ON public.changes USING btree (source_claim_id);


--
-- Name: changes_source_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX changes_source_document_id_index ON public.changes USING btree (source_document_id);


--
-- Name: changes_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX changes_status_index ON public.changes USING btree (status);


--
-- Name: chat_threads_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_threads_document_id_index ON public.chat_threads USING btree (document_id);


--
-- Name: chat_threads_last_message_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_threads_last_message_at_index ON public.chat_threads USING btree (last_message_at);


--
-- Name: chat_threads_owner_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX chat_threads_owner_id_index ON public.chat_threads USING btree (owner_id);


--
-- Name: document_types_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX document_types_key_index ON public.document_types USING btree (key);


--
-- Name: documents_document_type_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX documents_document_type_id_index ON public.documents USING btree (document_type_id);


--
-- Name: documents_owner_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX documents_owner_id_status_index ON public.documents USING btree (owner_id, status);


--
-- Name: documents_parent_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX documents_parent_document_id_index ON public.documents USING btree (parent_document_id);


--
-- Name: documents_type_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX documents_type_key_index ON public.documents USING btree (type_key);


--
-- Name: evidence_snapshots_chat_thread_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX evidence_snapshots_chat_thread_id_index ON public.evidence_snapshots USING btree (chat_thread_id);


--
-- Name: evidence_snapshots_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX evidence_snapshots_document_id_index ON public.evidence_snapshots USING btree (document_id);


--
-- Name: evidence_snapshots_provider_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX evidence_snapshots_provider_index ON public.evidence_snapshots USING btree (provider);


--
-- Name: evidence_snapshots_result_hash_owner_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX evidence_snapshots_result_hash_owner_id_index ON public.evidence_snapshots USING btree (result_hash, owner_id);


--
-- Name: evidence_snapshots_source_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX evidence_snapshots_source_document_id_index ON public.evidence_snapshots USING btree (source_document_id);


--
-- Name: exports_document_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX exports_document_id_inserted_at_index ON public.exports USING btree (document_id, inserted_at);


--
-- Name: exports_requester_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX exports_requester_id_inserted_at_index ON public.exports USING btree (requester_id, inserted_at);


--
-- Name: exports_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX exports_status_index ON public.exports USING btree (status);


--
-- Name: field_lineages_document_id_field_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX field_lineages_document_id_field_id_index ON public.field_lineages USING btree (document_id, field_id);


--
-- Name: field_lineages_source_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX field_lineages_source_document_id_index ON public.field_lineages USING btree (source_document_id);


--
-- Name: leases_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX leases_expires_at_index ON public.leases USING btree (expires_at);


--
-- Name: marks_change_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX marks_change_id_index ON public.marks USING btree (change_id);


--
-- Name: marks_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX marks_document_id_index ON public.marks USING btree (document_id);


--
-- Name: marks_evidence_snapshot_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX marks_evidence_snapshot_id_index ON public.marks USING btree (evidence_snapshot_id);


--
-- Name: matters_owner_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX matters_owner_id_index ON public.matters USING btree (owner_id);


--
-- Name: matters_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX matters_status_index ON public.matters USING btree (status);


--
-- Name: matters_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX matters_tenant_id_index ON public.matters USING btree (tenant_id);


--
-- Name: oban_jobs_args_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_args_index ON public.oban_jobs USING gin (args);


--
-- Name: oban_jobs_meta_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_meta_index ON public.oban_jobs USING gin (meta);


--
-- Name: oban_jobs_state_cancelled_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_cancelled_at_index ON public.oban_jobs USING btree (state, cancelled_at);


--
-- Name: oban_jobs_state_discarded_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_discarded_at_index ON public.oban_jobs USING btree (state, discarded_at);


--
-- Name: oban_jobs_state_queue_priority_scheduled_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index ON public.oban_jobs USING btree (state, queue, priority, scheduled_at, id);


--
-- Name: revoke_requests_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX revoke_requests_document_id_index ON public.revoke_requests USING btree (document_id);


--
-- Name: revoke_requests_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX revoke_requests_status_index ON public.revoke_requests USING btree (status);


--
-- Name: revoke_requests_target_change_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX revoke_requests_target_change_id_index ON public.revoke_requests USING btree (target_change_id);


--
-- Name: slack_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_tokens_user_id_index ON public.slack_tokens USING btree (user_id);


--
-- Name: slack_tokens_user_id_slack_team_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_tokens_user_id_slack_team_id_index ON public.slack_tokens USING btree (user_id, slack_team_id);


--
-- Name: snapshots_document_id_revision_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX snapshots_document_id_revision_index ON public.snapshots USING btree (document_id, revision);


--
-- Name: source_claims_linked_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX source_claims_linked_document_id_index ON public.source_claims USING btree (linked_document_id);


--
-- Name: source_claims_source_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX source_claims_source_document_id_index ON public.source_claims USING btree (source_document_id);


--
-- Name: source_claims_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX source_claims_status_index ON public.source_claims USING btree (status);


--
-- Name: source_documents_chat_thread_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX source_documents_chat_thread_id_index ON public.source_documents USING btree (chat_thread_id);


--
-- Name: source_documents_document_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX source_documents_document_id_index ON public.source_documents USING btree (document_id);


--
-- Name: source_documents_owner_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX source_documents_owner_id_index ON public.source_documents USING btree (owner_id);


--
-- Name: source_documents_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX source_documents_status_index ON public.source_documents USING btree (status);


--
-- Name: tool_calls_agent_run_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_calls_agent_run_id_index ON public.tool_calls USING btree (agent_run_id);


--
-- Name: tool_calls_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_calls_name_index ON public.tool_calls USING btree (name);


--
-- Name: tool_calls_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tool_calls_status_index ON public.tool_calls USING btree (status);


--
-- Name: users_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_index ON public.users USING btree (email);


--
-- Name: users_tokens_context_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_tokens_context_token_index ON public.users_tokens USING btree (context, token);


--
-- Name: users_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_tokens_user_id_index ON public.users_tokens USING btree (user_id);


--
-- Name: documents documents_document_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_document_type_id_fkey FOREIGN KEY (document_type_id) REFERENCES public.document_types(id) ON DELETE RESTRICT;


--
-- Name: exports exports_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exports
    ADD CONSTRAINT exports_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: slack_tokens slack_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_tokens
    ADD CONSTRAINT slack_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: users_tokens users_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict cpwDPyEt8gjthweZPPqGfgrbAnxoE3cnUUkbB2BxFNWfJTalb8dVmO2tyTfnVMY

INSERT INTO public."schema_migrations" (version) VALUES (20260515080502);
INSERT INTO public."schema_migrations" (version) VALUES (20260515080600);
INSERT INTO public."schema_migrations" (version) VALUES (20260515080700);
INSERT INTO public."schema_migrations" (version) VALUES (20260515080800);
INSERT INTO public."schema_migrations" (version) VALUES (20260515090000);
INSERT INTO public."schema_migrations" (version) VALUES (20260515091000);
INSERT INTO public."schema_migrations" (version) VALUES (20260515091100);
INSERT INTO public."schema_migrations" (version) VALUES (20260515100000);
INSERT INTO public."schema_migrations" (version) VALUES (20260515100100);
INSERT INTO public."schema_migrations" (version) VALUES (20260515100200);
INSERT INTO public."schema_migrations" (version) VALUES (20260515170000);
INSERT INTO public."schema_migrations" (version) VALUES (20260515200000);
INSERT INTO public."schema_migrations" (version) VALUES (20260516073201);
INSERT INTO public."schema_migrations" (version) VALUES (20260516073207);
INSERT INTO public."schema_migrations" (version) VALUES (20260516073209);
INSERT INTO public."schema_migrations" (version) VALUES (20260516073211);
INSERT INTO public."schema_migrations" (version) VALUES (20260516073212);
INSERT INTO public."schema_migrations" (version) VALUES (20260516073214);
INSERT INTO public."schema_migrations" (version) VALUES (20260516073216);
INSERT INTO public."schema_migrations" (version) VALUES (20260516073218);
INSERT INTO public."schema_migrations" (version) VALUES (20260517042210);
INSERT INTO public."schema_migrations" (version) VALUES (20260517063610);
INSERT INTO public."schema_migrations" (version) VALUES (20260517063839);
INSERT INTO public."schema_migrations" (version) VALUES (20260517071623);
INSERT INTO public."schema_migrations" (version) VALUES (20260519044040);
INSERT INTO public."schema_migrations" (version) VALUES (20260519051239);
