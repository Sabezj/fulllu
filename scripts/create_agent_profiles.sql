-- SQL schema for agent_profiles table
CREATE TABLE IF NOT EXISTS agent_profiles (
    id SERIAL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    instructions TEXT,
    voice TEXT,
    mood TEXT,
    rules TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
