--
-- PostgreSQL database dump
--

\restrict kfCve9RkrQF2n6leLU7NGz0xMYNkSOCS7KlUStMegRElOvbKXREGsfKjRQ4iD0F

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
    template_hwp_path text,
    template_hwpx_path text,
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
    latest_revision integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    owner_id uuid NOT NULL,
    document_type_id uuid,
    write_completed_at timestamp(0) without time zone,
    write_completed_by_id uuid,
    write_completed_revision integer,
    write_completed_snapshot_revision integer
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
-- Name: rhwp_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rhwp_snapshots (
    document_id uuid NOT NULL,
    revision integer NOT NULL,
    format character varying(255) NOT NULL,
    content_type character varying(255) NOT NULL,
    r2_key character varying(255) NOT NULL,
    ir_r2_key character varying(255) NOT NULL,
    projection jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
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
-- Name: leases leases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leases
    ADD CONSTRAINT leases_pkey PRIMARY KEY (document_id);


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
-- Name: rhwp_snapshots rhwp_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rhwp_snapshots
    ADD CONSTRAINT rhwp_snapshots_pkey PRIMARY KEY (document_id, revision);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: snapshots snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.snapshots
    ADD CONSTRAINT snapshots_pkey PRIMARY KEY (document_id, revision);


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
-- Name: documents_type_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX documents_type_key_index ON public.documents USING btree (type_key);


--
-- Name: documents_write_completed_by_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX documents_write_completed_by_id_index ON public.documents USING btree (write_completed_by_id);


--
-- Name: leases_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX leases_expires_at_index ON public.leases USING btree (expires_at);


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
-- Name: rhwp_snapshots_document_id_format_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rhwp_snapshots_document_id_format_index ON public.rhwp_snapshots USING btree (document_id, format);


--
-- Name: rhwp_snapshots_document_id_revision_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rhwp_snapshots_document_id_revision_index ON public.rhwp_snapshots USING btree (document_id, revision);


--
-- Name: rhwp_snapshots_ir_r2_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX rhwp_snapshots_ir_r2_key_index ON public.rhwp_snapshots USING btree (ir_r2_key);


--
-- Name: rhwp_snapshots_r2_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX rhwp_snapshots_r2_key_index ON public.rhwp_snapshots USING btree (r2_key);


--
-- Name: snapshots_document_id_revision_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX snapshots_document_id_revision_index ON public.snapshots USING btree (document_id, revision);


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
-- Name: users_tokens users_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict kfCve9RkrQF2n6leLU7NGz0xMYNkSOCS7KlUStMegRElOvbKXREGsfKjRQ4iD0F

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
INSERT INTO public."schema_migrations" (version) VALUES (20260523185150);
INSERT INTO public."schema_migrations" (version) VALUES (20260525155101);
INSERT INTO public."schema_migrations" (version) VALUES (20260526163731);
