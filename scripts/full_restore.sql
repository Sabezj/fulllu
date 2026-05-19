--
-- PostgreSQL database dump
--

-- Dumped from database version 16.9 (Ubuntu 16.9-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.9 (Ubuntu 16.9-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agent_profiles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.agent_profiles (
    id integer NOT NULL,
    name text NOT NULL,
    instructions text,
    voice text,
    mood text,
    rules text,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.agent_profiles OWNER TO postgres;

--
-- Name: agent_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.agent_profiles_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.agent_profiles_id_seq OWNER TO postgres;

--
-- Name: agent_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.agent_profiles_id_seq OWNED BY public.agent_profiles.id;


--
-- Name: analytics; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.analytics (
    id integer NOT NULL,
    session_id text,
    duration_ms integer,
    tokens integer,
    queries integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.analytics OWNER TO postgres;

--
-- Name: analytics_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.analytics_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.analytics_id_seq OWNER TO postgres;

--
-- Name: analytics_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.analytics_id_seq OWNED BY public.analytics.id;


--
-- Name: cart_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.cart_items (
    cart_id bigint NOT NULL,
    product_id bigint NOT NULL,
    qty integer NOT NULL,
    price_cents_at_add integer NOT NULL,
    CONSTRAINT cart_items_price_cents_at_add_check CHECK ((price_cents_at_add >= 0)),
    CONSTRAINT cart_items_qty_check CHECK ((qty > 0))
);


ALTER TABLE public.cart_items OWNER TO postgres;

--
-- Name: carts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.carts (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT carts_status_check CHECK ((status = ANY (ARRAY['open'::text, 'submitted'::text, 'cancelled'::text])))
);


ALTER TABLE public.carts OWNER TO postgres;

--
-- Name: carts_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.carts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.carts_id_seq OWNER TO postgres;

--
-- Name: carts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.carts_id_seq OWNED BY public.carts.id;


--
-- Name: orders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.orders (
    id integer NOT NULL,
    user_id text NOT NULL,
    product_id integer,
    qty integer,
    total numeric,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.orders OWNER TO postgres;

--
-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.orders_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.orders_id_seq OWNER TO postgres;

--
-- Name: orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.orders_id_seq OWNED BY public.orders.id;


--
-- Name: product_embeddings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.product_embeddings (
    product_id integer NOT NULL,
    embedding public.vector(1536)
);


ALTER TABLE public.product_embeddings OWNER TO postgres;

--
-- Name: products; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.products (
    id bigint NOT NULL,
    name text NOT NULL,
    description text,
    price_cents integer NOT NULL,
    sku text NOT NULL,
    stock integer DEFAULT 0 NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT products_price_cents_check CHECK ((price_cents >= 0)),
    CONSTRAINT products_stock_check CHECK ((stock >= 0))
);


ALTER TABLE public.products OWNER TO postgres;

--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.products_id_seq OWNER TO postgres;

--
-- Name: products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.products_id_seq OWNED BY public.products.id;


--
-- Name: schema_version; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.schema_version (
    version integer NOT NULL,
    applied_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.schema_version OWNER TO postgres;

--
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users (
    id integer NOT NULL,
    phone text,
    name text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.users OWNER TO postgres;

--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.users_id_seq OWNER TO postgres;

--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: agent_profiles id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agent_profiles ALTER COLUMN id SET DEFAULT nextval('public.agent_profiles_id_seq'::regclass);


--
-- Name: analytics id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.analytics ALTER COLUMN id SET DEFAULT nextval('public.analytics_id_seq'::regclass);


--
-- Name: carts id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.carts ALTER COLUMN id SET DEFAULT nextval('public.carts_id_seq'::regclass);


--
-- Name: orders id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders ALTER COLUMN id SET DEFAULT nextval('public.orders_id_seq'::regclass);


--
-- Name: products id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products ALTER COLUMN id SET DEFAULT nextval('public.products_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Data for Name: agent_profiles; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.agent_profiles (id, name, instructions, voice, mood, rules, created_at) FROM stdin;
1	Boost-Seller	Guide B2B customers through your Postgres-backed product catalog, pull exact data (price, SKU, stock), answer questions, assemble carts, and confirm or adjust orders with zero perceptible delay. Always begin by briefly identifying yourself and (if obvious) choosing the best-fit persona. Default to Tech-Expert unless the caller’s style or request suggests switching; announce the change once. Reference real-time inventory from the Postgres DB using structured queries; surface only what the caller asked for plus one relevant upsell if in Boost-Seller mode. When a caller gives names, addresses, numbers, or SKUs, repeat them back *exactly* for confirmation before proceeding. Close every order by summarizing line items, quantities, total price, and expected delivery date, then ask for explicit vocal confirmation. If the caller corrects any detail, acknowledge plainly and restate the corrected value. Keep answers under 30 seconds unless further depth is requested.	ash	energetic	You are an energetic, motivational salesperson who keeps the conversation lively, highlights value, and nudges the client toward quick decisions. Balanced: always respectful and client-oriented. Tone: Neutral-friendly, professional yet approachable Russian business speech (Вы-форма). Enthusiasm: High. Formality: Medium. Emotion: Moderate warmth. Filler Words: Occasionally insert natural interjections (“мм”, “ну”, “хм”). Pacing: Steady tempo with brief pauses.	2025-08-05 16:23:51.457867
2	Care-Advisor	Guide B2B customers through your Postgres-backed product catalog, pull exact data (price, SKU, stock), answer questions, assemble carts, and confirm or adjust orders with zero perceptible delay. Always begin by briefly identifying yourself and (if obvious) choosing the best-fit persona. Default to Tech-Expert unless the caller’s style or request suggests switching; announce the change once. Reference real-time inventory from the Postgres DB using structured queries; surface only what the caller asked for. When a caller gives names, addresses, numbers, or SKUs, repeat them back *exactly* for confirmation before proceeding. Close every order by summarizing line items, quantities, total price, and expected delivery date, then ask for explicit vocal confirmation. If the caller corrects any detail, acknowledge plainly and restate the corrected value. Keep answers under 30 seconds unless further depth is requested.	ash	gentle	You are a gentle, empathetic consultant who reassures customers, explains choices in plain language, and checks understanding at every step. Balanced: always respectful and client-oriented. Tone: Neutral-friendly, professional yet approachable Russian business speech (Вы-форма). Enthusiasm: Medium. Formality: Medium. Emotion: Moderate warmth. Filler Words: Occasionally insert natural interjections (“мм”, “ну”, “хм”). Pacing: Steady tempo with brief pauses.	2025-08-05 16:24:06.073915
3	Tech-Expert	Guide B2B customers through your Postgres-backed product catalog, pull exact data (price, SKU, stock), answer questions, assemble carts, and confirm or adjust orders with zero perceptible delay. Always begin by briefly identifying yourself and (if obvious) choosing the best-fit persona. Default to Tech-Expert unless the caller’s style or request suggests switching; announce the change once. Reference real-time inventory from the Postgres DB using structured queries; surface only what the caller asked for. When a caller gives names, addresses, numbers, or SKUs, repeat them back *exactly* for confirmation before proceeding. Close every order by summarizing line items, quantities, total price, and expected delivery date, then ask for explicit vocal confirmation. If the caller corrects any detail, acknowledge plainly and restate the corrected value. Keep answers under 30 seconds unless further depth is requested.	ash	calm	You are a calm, maximally precise product specialist who speaks in concise, data-rich sentences and delights in technical detail. Balanced: always respectful and client-oriented. Tone: Neutral-friendly, professional yet approachable Russian business speech (Вы-форма). Enthusiasm: Low. Formality: High. Emotion: Low. Filler Words: Occasionally insert natural interjections (“мм”, “ну”, “хм”). Pacing: Steady tempo with brief pauses.	2025-08-05 16:24:24.538882
\.


--
-- Data for Name: analytics; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.analytics (id, session_id, duration_ms, tokens, queries, created_at) FROM stdin;
1	sess_C1BM8xswxraiHqjLEJIUg	111133	96	6	2025-08-05 15:48:43.239891
2	sess_C1BOkhCPD4jHWzvvSK6Dz	87836	201	12	2025-08-05 15:51:02.63832
3	sess_C1CJkDD36CQL3JEn9BhTB	151329	293	12	2025-08-05 16:51:00.864681
4	sess_C1Clq41sjpCa2tvZ1QosE	265218	666	48	2025-08-05 17:21:57.858358
5	sess_C1CqO9PEnp86Il1uOp70a	219743	619	26	2025-08-05 17:25:55.084226
6	sess_C1CqO9PEnp86Il1uOp70a	253	0	0	2025-08-05 23:13:16.150778
7	sess_C1ILBTYpvG4IUsamBVfI4	86665	41	8	2025-08-05 23:15:07.435616
8	\N	\N	0	0	2025-08-06 23:20:29.103586
9	\N	\N	0	0	2025-08-06 23:21:43.260697
10	\N	\N	41	8	2025-08-06 23:24:10.185845
11	\N	\N	120	9	2025-08-06 23:25:11.525561
12	\N	\N	0	0	2025-08-06 23:35:53.499932
13	\N	\N	0	0	2025-08-06 23:39:21.051085
14	\N	\N	324	20	2025-08-06 23:42:57.866938
15	\N	\N	268	16	2025-08-06 23:48:44.212477
16	\N	\N	207	28	2025-08-07 00:13:22.951833
17	\N	\N	0	0	2025-08-07 02:00:10.767582
18	\N	\N	0	0	2025-08-07 02:00:12.668194
19	\N	\N	0	0	2025-08-07 02:00:13.471629
20	\N	\N	0	0	2025-08-07 02:00:33.166019
21	\N	\N	0	0	2025-08-07 02:00:34.303661
22	\N	\N	0	0	2025-08-07 02:28:31.075096
23	\N	\N	0	0	2025-08-07 02:28:32.870431
24	\N	\N	0	0	2025-08-07 02:29:25.101623
25	\N	\N	0	0	2025-08-07 02:29:26.993101
26	\N	\N	0	0	2025-08-07 02:41:14.982566
27	\N	\N	0	0	2025-08-07 02:45:27.182266
28	\N	\N	0	0	2025-08-07 02:45:28.000522
29	\N	\N	0	0	2025-08-07 02:45:29.725633
30	\N	\N	0	0	2025-08-07 02:45:35.538756
31	\N	\N	0	0	2025-08-07 02:51:24.331536
32	\N	\N	257	20	2025-08-07 02:53:25.537432
33	\N	\N	0	0	2025-08-07 03:30:57.52448
34	\N	\N	0	0	2025-08-07 03:30:57.524912
35	\N	\N	484	53	2025-08-07 03:36:45.001937
36	\N	\N	0	0	2025-08-07 03:57:26.125335
37	\N	\N	315	36	2025-08-07 04:00:18.414625
38	\N	\N	315	10	2025-08-07 04:49:14.355927
39	\N	\N	89	6	2025-08-07 04:50:05.526097
40	\N	\N	143	13	2025-08-07 05:03:56.821225
41	\N	\N	215	12	2025-08-07 05:08:01.180416
42	\N	\N	106	6	2025-08-07 05:15:41.806614
43	\N	\N	172	8	2025-08-07 06:50:48.223145
44	\N	\N	396	24	2025-08-07 06:57:10.443125
\.


--
-- Data for Name: cart_items; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.cart_items (cart_id, product_id, qty, price_cents_at_add) FROM stdin;
\.


--
-- Data for Name: carts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.carts (id, user_id, status, created_at) FROM stdin;
\.


--
-- Data for Name: orders; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.orders (id, user_id, product_id, qty, total, created_at) FROM stdin;
\.


--
-- Data for Name: product_embeddings; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.product_embeddings (product_id, embedding) FROM stdin;
\.


--
-- Data for Name: products; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.products (id, name, description, price_cents, sku, stock, created_at) FROM stdin;
85	МП-10х1100- А, В	1200 мм общая ширина, 1100.0 мм рабочая ширина, 0.45 мм толщина, Оцинковка	44917	МП-10х1100- А, В_0.45_1200	0	2025-08-05 13:25:10.230715
86	МП-10х1100- А, В	1200 мм общая ширина, 1100.0 мм рабочая ширина, 0.55 мм толщина, Оцинковка	54821	МП-10х1100- А, В_0.55_1200	0	2025-08-05 13:25:10.230715
87	МП-10х1100- А, В	1200 мм общая ширина, 1100.0 мм рабочая ширина, 0.5 мм толщина, Оцинковка	47925	МП-10х1100- А, В_0.5_1200	0	2025-08-05 13:25:10.230715
88	МП-10х1100- А, В	1200 мм общая ширина, 1100.0 мм рабочая ширина, 0.65 мм толщина, Оцинковка	63250	МП-10х1100- А, В_0.65_1200	0	2025-08-05 13:25:10.230715
89	МП-10х1100- А, В	1200 мм общая ширина, 1100.0 мм рабочая ширина, 0.6 мм толщина, Оцинковка	59466	МП-10х1100- А, В_0.6_1200	0	2025-08-05 13:25:10.230715
90	МП-10х1100- А, В	1200 мм общая ширина, 1100.0 мм рабочая ширина, 0.7 мм толщина, Оцинковка	65983	МП-10х1100- А, В_0.7_1200	0	2025-08-05 13:25:10.230715
91	МП-18 х 1100- А, В	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.55 мм толщина, Оцинковка	57204	МП-18 х 1100- А, В_0.55_1150	0	2025-08-05 13:25:10.230715
92	МП-18 х 1100- А, В	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.5 мм толщина, Оцинковка	50009	МП-18 х 1100- А, В_0.5_1150	0	2025-08-05 13:25:10.230715
93	МП-18 х 1100- А, В	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.65 мм толщина, Оцинковка	66000	МП-18 х 1100- А, В_0.65_1150	0	2025-08-05 13:25:10.230715
94	МП-18 х 1100- А, В	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.6 мм толщина, Оцинковка	62052	МП-18 х 1100- А, В_0.6_1150	0	2025-08-05 13:25:10.230715
95	МП-18 х 1100- А, В	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.7 мм толщина, Оцинковка	68852	МП-18 х 1100- А, В_0.7_1150	0	2025-08-05 13:25:10.230715
96	МП-20 х 1100- А, В, R	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.45 мм толщина, Оцинковка	46870	МП-20 х 1100- А, В, R_0.45_1150	0	2025-08-05 13:25:10.230715
97	МП-20 х 1100- А, В, R	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.4 мм толщина, Оцинковка	41322	МП-20 х 1100- А, В, R_0.4_1150	0	2025-08-05 13:25:10.230715
98	МП-20 х 1100- А, В, R	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.55 мм толщина, Оцинковка	57204	МП-20 х 1100- А, В, R_0.55_1150	0	2025-08-05 13:25:10.230715
99	МП-20 х 1100- А, В, R	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.5 мм толщина, Оцинковка	50009	МП-20 х 1100- А, В, R_0.5_1150	0	2025-08-05 13:25:10.230715
100	МП-20 х 1100- А, В, R	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.65 мм толщина, Оцинковка	66000	МП-20 х 1100- А, В, R_0.65_1150	0	2025-08-05 13:25:10.230715
101	МП-20 х 1100- А, В, R	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.6 мм толщина, Оцинковка	62052	МП-20 х 1100- А, В, R_0.6_1150	0	2025-08-05 13:25:10.230715
102	МП-20 х 1100- А, В, R	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.75 мм толщина, Оцинковка	73504	МП-20 х 1100- А, В, R_0.75_1150	0	2025-08-05 13:25:10.230715
103	МП-20 х 1100- А, В, R	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.7 мм толщина, Оцинковка	68852	МП-20 х 1100- А, В, R_0.7_1150	0	2025-08-05 13:25:10.230715
104	МП-20 х 1100- А, В, R	1150 мм общая ширина, 1100.0 мм рабочая ширина, 0.8 мм толщина, Оцинковка	76696	МП-20 х 1100- А, В, R_0.8_1150	0	2025-08-05 13:25:10.230715
105	МП-35 х 1035- А, В	1076 мм общая ширина, 1035.0 мм рабочая ширина, 0.55 мм толщина, Оцинковка	61138	МП-35 х 1035- А, В_0.55_1076	0	2025-08-05 13:25:10.230715
106	МП-35 х 1035- А, В	1076 мм общая ширина, 1035.0 мм рабочая ширина, 0.5 мм толщина, Оцинковка	53448	МП-35 х 1035- А, В_0.5_1076	0	2025-08-05 13:25:10.230715
107	МП-35 х 1035- А, В	1076 мм общая ширина, 1035.0 мм рабочая ширина, 0.65 мм толщина, Оцинковка	70539	МП-35 х 1035- А, В_0.65_1076	0	2025-08-05 13:25:10.230715
108	МП-35 х 1035- А, В	1076 мм общая ширина, 1035.0 мм рабочая ширина, 0.6 мм толщина, Оцинковка	66320	МП-35 х 1035- А, В_0.6_1076	0	2025-08-05 13:25:10.230715
109	МП-35 х 1035- А, В	1076 мм общая ширина, 1035.0 мм рабочая ширина, 0.75 мм толщина, Оцинковка	78559	МП-35 х 1035- А, В_0.75_1076	0	2025-08-05 13:25:10.230715
110	МП-35 х 1035- А, В	1076 мм общая ширина, 1035.0 мм рабочая ширина, 0.7 мм толщина, Оцинковка	73587	МП-35 х 1035- А, В_0.7_1076	0	2025-08-05 13:25:10.230715
111	МП-35 х 1035- А, В	1076 мм общая ширина, 1035.0 мм рабочая ширина, 0.8 мм толщина, Оцинковка	81970	МП-35 х 1035- А, В_0.8_1076	0	2025-08-05 13:25:10.230715
112	МП-35 х 1035- А, В	1076 мм общая ширина, 1035.0 мм рабочая ширина, 0.9 мм толщина, Оцинковка	96803	МП-35 х 1035- А, В_0.9_1076	0	2025-08-05 13:25:10.230715
113	Н-114 х 750- А, В	807 мм общая ширина, 750.0 мм рабочая ширина, 1.2 мм толщина, Оцинковка	135118	Н-114 х 750- А, В_1.2_807	0	2025-08-05 13:25:10.230715
114	Н-114 х 750- А, В	807 мм общая ширина, 750.0 мм рабочая ширина, 1.5 мм толщина, Оцинковка	145725	Н-114 х 750- А, В_1.5_807	0	2025-08-05 13:25:10.230715
115	Н-114 х 750- А, В	807 мм общая ширина, 750.0 мм рабочая ширина, 2.0 мм толщина, Оцинковка	159554	Н-114 х 750- А, В_2.0_807	0	2025-08-05 13:25:10.230715
116	Н-60 х 845- А, В	902 мм общая ширина, 845.0 мм рабочая ширина, 0.55 мм толщина, Оцинковка	72932	Н-60 х 845- А, В_0.55_902	0	2025-08-05 13:25:10.230715
117	Н-60 х 845- А, В	902 мм общая ширина, 845.0 мм рабочая ширина, 0.65 мм толщина, Оцинковка	84146	Н-60 х 845- А, В_0.65_902	0	2025-08-05 13:25:10.230715
118	Н-60 х 845- А, В	902 мм общая ширина, 845.0 мм рабочая ширина, 0.6 мм толщина, Оцинковка	79113	Н-60 х 845- А, В_0.6_902	0	2025-08-05 13:25:10.230715
119	Н-60 х 845- А, В	902 мм общая ширина, 845.0 мм рабочая ширина, 0.75 мм толщина, Оцинковка	93714	Н-60 х 845- А, В_0.75_902	0	2025-08-05 13:25:10.230715
120	Н-60 х 845- А, В	902 мм общая ширина, 845.0 мм рабочая ширина, 0.7 мм толщина, Оцинковка	87783	Н-60 х 845- А, В_0.7_902	0	2025-08-05 13:25:10.230715
121	Н-60 х 845- А, В	902 мм общая ширина, 845.0 мм рабочая ширина, 0.8 мм толщина, Оцинковка	97783	Н-60 х 845- А, В_0.8_902	0	2025-08-05 13:25:10.230715
122	Н-60 х 845- А, В	902 мм общая ширина, 845.0 мм рабочая ширина, 0.9 мм толщина, Оцинковка	115477	Н-60 х 845- А, В_0.9_902	0	2025-08-05 13:25:10.230715
123	Н-60 х 845- А, В	902 мм общая ширина, 845.0 мм рабочая ширина, 1.0 мм толщина, Оцинковка	126181	Н-60 х 845- А, В_1.0_902	0	2025-08-05 13:25:10.230715
124	Н-75 х 750- А, В	800 мм общая ширина, 750.0 мм рабочая ширина, 0.75 мм толщина, Оцинковка	98975	Н-75 х 750- А, В_0.75_800	0	2025-08-05 13:25:10.230715
125	Н-75 х 750- А, В	800 мм общая ширина, 750.0 мм рабочая ширина, 0.7 мм толщина, Оцинковка	94875	Н-75 х 750- А, В_0.7_800	0	2025-08-05 13:25:10.230715
126	Н-75 х 750- А, В	800 мм общая ширина, 750.0 мм рабочая ширина, 0.8 мм толщина, Оцинковка	105663	Н-75 х 750- А, В_0.8_800	0	2025-08-05 13:25:10.230715
127	Н-75 х 750- А, В	800 мм общая ширина, 750.0 мм рабочая ширина, 0.9 мм толщина, Оцинковка	110250	Н-75 х 750- А, В_0.9_800	0	2025-08-05 13:25:10.230715
128	Н-75 х 750- А, В	800 мм общая ширина, 750.0 мм рабочая ширина, 1.0 мм толщина, Оцинковка	130200	Н-75 х 750- А, В_1.0_800	0	2025-08-05 13:25:10.230715
129	Н-75 х 750- А, В	800 мм общая ширина, 750.0 мм рабочая ширина, 1.2 мм толщина, Оцинковка	142269	Н-75 х 750- А, В_1.2_800	0	2025-08-05 13:25:10.230715
130	НС-35 х1000- А, В	1060 мм общая ширина, 1000.0 мм рабочая ширина, 0.55 мм толщина, Оцинковка	62061	НС-35 х1000- А, В_0.55_1060	0	2025-08-05 13:25:10.230715
131	НС-35 х1000- А, В	1060 мм общая ширина, 1000.0 мм рабочая ширина, 0.5 мм толщина, Оцинковка	54254	НС-35 х1000- А, В_0.5_1060	0	2025-08-05 13:25:10.230715
132	НС-35 х1000- А, В	1060 мм общая ширина, 1000.0 мм рабочая ширина, 0.65 мм толщина, Оцинковка	71604	НС-35 х1000- А, В_0.65_1060	0	2025-08-05 13:25:10.230715
133	НС-35 х1000- А, В	1060 мм общая ширина, 1000.0 мм рабочая ширина, 0.6 мм толщина, Оцинковка	67321	НС-35 х1000- А, В_0.6_1060	0	2025-08-05 13:25:10.230715
134	НС-35 х1000- А, В	1060 мм общая ширина, 1000.0 мм рабочая ширина, 0.75 мм толщина, Оцинковка	79745	НС-35 х1000- А, В_0.75_1060	0	2025-08-05 13:25:10.230715
135	НС-35 х1000- А, В	1060 мм общая ширина, 1000.0 мм рабочая ширина, 0.7 мм толщина, Оцинковка	74698	НС-35 х1000- А, В_0.7_1060	0	2025-08-05 13:25:10.230715
136	НС-35 х1000- А, В	1060 мм общая ширина, 1000.0 мм рабочая ширина, 0.8 мм толщина, Оцинковка	83208	НС-35 х1000- А, В_0.8_1060	0	2025-08-05 13:25:10.230715
137	НС-35 х1000- А, В	1060 мм общая ширина, 1000.0 мм рабочая ширина, 0.9 мм толщина, Оцинковка	98264	НС-35 х1000- А, В_0.9_1060	0	2025-08-05 13:25:10.230715
138	Плоский лист *****	1250 мм общая ширина, 0.45 мм толщина, Оцинковка	43120	Плоский лист *****_0.45_1250	0	2025-08-05 13:25:10.230715
139	Плоский лист *****	1250 мм общая ширина, 0.4 мм толщина, Оцинковка	38016	Плоский лист *****_0.4_1250	0	2025-08-05 13:25:10.230715
140	Плоский лист *****	1250 мм общая ширина, 0.55 мм толщина, Оцинковка	52628	Плоский лист *****_0.55_1250	0	2025-08-05 13:25:10.230715
141	Плоский лист *****	1250 мм общая ширина, 0.5 мм толщина, Оцинковка	46008	Плоский лист *****_0.5_1250	0	2025-08-05 13:25:10.230715
142	Плоский лист *****	1250 мм общая ширина, 0.65 мм толщина, Оцинковка	60720	Плоский лист *****_0.65_1250	0	2025-08-05 13:25:10.230715
143	Плоский лист *****	1250 мм общая ширина, 0.6 мм толщина, Оцинковка	57088	Плоский лист *****_0.6_1250	0	2025-08-05 13:25:10.230715
144	Плоский лист *****	1250 мм общая ширина, 0.75 мм толщина, Оцинковка	67624	Плоский лист *****_0.75_1250	0	2025-08-05 13:25:10.230715
145	Плоский лист *****	1250 мм общая ширина, 0.7 мм толщина, Оцинковка	63344	Плоский лист *****_0.7_1250	0	2025-08-05 13:25:10.230715
146	Плоский лист *****	1250 мм общая ширина, 0.8 мм толщина, Оцинковка	70560	Плоский лист *****_0.8_1250	0	2025-08-05 13:25:10.230715
147	Плоский лист *****	1250 мм общая ширина, 0.9 мм толщина, Оцинковка	83328	Плоский лист *****_0.9_1250	0	2025-08-05 13:25:10.230715
148	Плоский лист *****	1250 мм общая ширина, 1.0 мм толщина, Оцинковка	91052	Плоский лист *****_1.0_1250	0	2025-08-05 13:25:10.230715
149	Плоский лист *****	1250 мм общая ширина, 1.2 мм толщина, Оцинковка	110208	Плоский лист *****_1.2_1250	0	2025-08-05 13:25:10.230715
150	Плоский лист *****	1250 мм общая ширина, 1.5 мм толщина, Оцинковка	136192	Плоский лист *****_1.5_1250	0	2025-08-05 13:25:10.230715
151	Плоский лист *****	1250 мм общая ширина, 2.0 мм толщина, Оцинковка	180096	Плоский лист *****_2.0_1250	0	2025-08-05 13:25:10.230715
152	С-21 х 1000- А, В	1051 мм общая ширина, 1000.0 мм рабочая ширина, 0.45 мм толщина, Оцинковка	51284	С-21 х 1000- А, В_0.45_1051	0	2025-08-05 13:25:10.230715
153	С-21 х 1000- А, В	1051 мм общая ширина, 1000.0 мм рабочая ширина, 0.4 мм толщина, Оцинковка	45214	С-21 х 1000- А, В_0.4_1051	0	2025-08-05 13:25:10.230715
154	С-21 х 1000- А, В	1051 мм общая ширина, 1000.0 мм рабочая ширина, 0.55 мм толщина, Оцинковка	62592	С-21 х 1000- А, В_0.55_1051	0	2025-08-05 13:25:10.230715
155	С-21 х 1000- А, В	1051 мм общая ширина, 1000.0 мм рабочая ширина, 0.5 мм толщина, Оцинковка	54719	С-21 х 1000- А, В_0.5_1051	0	2025-08-05 13:25:10.230715
156	С-21 х 1000- А, В	1051 мм общая ширина, 1000.0 мм рабочая ширина, 0.65 мм толщина, Оцинковка	72217	С-21 х 1000- А, В_0.65_1051	0	2025-08-05 13:25:10.230715
157	С-21 х 1000- А, В	1051 мм общая ширина, 1000.0 мм рабочая ширина, 0.6 мм толщина, Оцинковка	67897	С-21 х 1000- А, В_0.6_1051	0	2025-08-05 13:25:10.230715
158	С-21 х 1000- А, В	1051 мм общая ширина, 1000.0 мм рабочая ширина, 0.7 мм толщина, Оцинковка	75338	С-21 х 1000- А, В_0.7_1051	0	2025-08-05 13:25:10.230715
159	С-44 х 1000- А, В	1047 мм общая ширина, 1000.0 мм рабочая ширина, 0.55 мм толщина, Оцинковка	62832	С-44 х 1000- А, В_0.55_1047	0	2025-08-05 13:25:10.230715
160	С-44 х 1000- А, В	1047 мм общая ширина, 1000.0 мм рабочая ширина, 0.5 мм толщина, Оцинковка	54928	С-44 х 1000- А, В_0.5_1047	0	2025-08-05 13:25:10.230715
161	С-44 х 1000- А, В	1047 мм общая ширина, 1000.0 мм рабочая ширина, 0.65 мм толщина, Оцинковка	72493	С-44 х 1000- А, В_0.65_1047	0	2025-08-05 13:25:10.230715
162	С-44 х 1000- А, В	1047 мм общая ширина, 1000.0 мм рабочая ширина, 0.6 мм толщина, Оцинковка	68157	С-44 х 1000- А, В_0.6_1047	0	2025-08-05 13:25:10.230715
163	С-44 х 1000- А, В	1047 мм общая ширина, 1000.0 мм рабочая ширина, 0.75 мм толщина, Оцинковка	80735	С-44 х 1000- А, В_0.75_1047	0	2025-08-05 13:25:10.230715
164	С-44 х 1000- А, В	1047 мм общая ширина, 1000.0 мм рабочая ширина, 0.7 мм толщина, Оцинковка	75626	С-44 х 1000- А, В_0.7_1047	0	2025-08-05 13:25:10.230715
165	С-44 х 1000- А, В	1047 мм общая ширина, 1000.0 мм рабочая ширина, 0.8 мм толщина, Оцинковка	84241	С-44 х 1000- А, В_0.8_1047	0	2025-08-05 13:25:10.230715
166	С-8 х 1150- А, В	1200 мм общая ширина, 1150.0 мм рабочая ширина, 0.45 мм толщина, Оцинковка	44917	С-8 х 1150- А, В_0.45_1200	0	2025-08-05 13:25:10.230715
167	С-8 х 1150- А, В	1200 мм общая ширина, 1150.0 мм рабочая ширина, 0.4 мм толщина, Оцинковка	39600	С-8 х 1150- А, В_0.4_1200	0	2025-08-05 13:25:10.230715
168	С-8 х 1150- А, В	1200 мм общая ширина, 1150.0 мм рабочая ширина, 0.55 мм толщина, Оцинковка	54821	С-8 х 1150- А, В_0.55_1200	0	2025-08-05 13:25:10.230715
169	С-8 х 1150- А, В	1200 мм общая ширина, 1150.0 мм рабочая ширина, 0.5 мм толщина, Оцинковка	47925	С-8 х 1150- А, В_0.5_1200	0	2025-08-05 13:25:10.230715
170	С-8 х 1150- А, В	1200 мм общая ширина, 1150.0 мм рабочая ширина, 0.65 мм толщина, Оцинковка	63250	С-8 х 1150- А, В_0.65_1200	0	2025-08-05 13:25:10.230715
171	С-8 х 1150- А, В	1200 мм общая ширина, 1150.0 мм рабочая ширина, 0.6 мм толщина, Оцинковка	59466	С-8 х 1150- А, В_0.6_1200	0	2025-08-05 13:25:10.230715
172	С-8 х 1150- А, В	1200 мм общая ширина, 1150.0 мм рабочая ширина, 0.7 мм толщина, Оцинковка	65983	С-8 х 1150- А, В_0.7_1200	0	2025-08-05 13:25:10.230715
\.


--
-- Data for Name: schema_version; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.schema_version (version, applied_at) FROM stdin;
1	2025-08-05 13:10:26.535356
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.users (id, phone, name, created_at) FROM stdin;
\.


--
-- Name: agent_profiles_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.agent_profiles_id_seq', 3, true);


--
-- Name: analytics_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.analytics_id_seq', 44, true);


--
-- Name: carts_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.carts_id_seq', 1, false);


--
-- Name: orders_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.orders_id_seq', 1, false);


--
-- Name: products_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.products_id_seq', 172, true);


--
-- Name: users_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.users_id_seq', 1, false);


--
-- Name: agent_profiles agent_profiles_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agent_profiles
    ADD CONSTRAINT agent_profiles_name_key UNIQUE (name);


--
-- Name: agent_profiles agent_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agent_profiles
    ADD CONSTRAINT agent_profiles_pkey PRIMARY KEY (id);


--
-- Name: analytics analytics_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.analytics
    ADD CONSTRAINT analytics_pkey PRIMARY KEY (id);


--
-- Name: cart_items cart_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cart_items
    ADD CONSTRAINT cart_items_pkey PRIMARY KEY (cart_id, product_id);


--
-- Name: carts carts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.carts
    ADD CONSTRAINT carts_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: product_embeddings product_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_embeddings
    ADD CONSTRAINT product_embeddings_pkey PRIMARY KEY (product_id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: products products_sku_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_sku_key UNIQUE (sku);


--
-- Name: schema_version schema_version_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.schema_version
    ADD CONSTRAINT schema_version_pkey PRIMARY KEY (version);


--
-- Name: users users_phone_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_phone_name_key UNIQUE (phone, name);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: product_embeddings_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX product_embeddings_idx ON public.product_embeddings USING hnsw (embedding public.vector_cosine_ops) WITH (m='16', ef_construction='64');


--
-- Name: products_search_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX products_search_idx ON public.products USING gin (to_tsvector('simple'::regconfig, ((name || ' '::text) || COALESCE(description, ''::text))));


--
-- Name: cart_items cart_items_cart_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cart_items
    ADD CONSTRAINT cart_items_cart_id_fkey FOREIGN KEY (cart_id) REFERENCES public.carts(id) ON DELETE CASCADE;


--
-- Name: cart_items cart_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cart_items
    ADD CONSTRAINT cart_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: orders orders_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: product_embeddings product_embeddings_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_embeddings
    ADD CONSTRAINT product_embeddings_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

