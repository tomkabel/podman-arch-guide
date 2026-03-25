-- ============================================
-- PostgreSQL Initialization Script
-- Place in init-scripts/ directory
-- Runs on first container startup
-- ============================================

-- Create application user with limited privileges
CREATE USER appuser WITH PASSWORD '${POSTGRES_PASSWORD}';

-- Create application database
CREATE DATABASE appdb OWNER appuser;

-- Connect to appdb
\c appdb;

-- Create schema
CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION appuser;

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE appdb TO appuser;
GRANT ALL PRIVILEGES ON SCHEMA app TO appuser;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA app TO appuser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA app TO appuser;

-- Create extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Set up Row Level Security (example)
-- ALTER TABLE app.users ENABLE ROW LEVEL SECURITY;

-- Create health check function
CREATE OR REPLACE FUNCTION public.health_check()
RETURNS TABLE (status text, timestamp timestamptz) AS $$
BEGIN
    RETURN QUERY SELECT 'healthy'::text, NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute on health check
GRANT EXECUTE ON FUNCTION public.health_check() TO appuser;

-- Create example table (customize for your app)
CREATE TABLE IF NOT EXISTS app.config (
    id SERIAL PRIMARY KEY,
    key VARCHAR(255) UNIQUE NOT NULL,
    value TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Insert default config
INSERT INTO app.config (key, value) VALUES
    ('app_version', '1.0.0'),
    ('maintenance_mode', 'false')
ON CONFLICT (key) DO NOTHING;

-- Create update trigger for updated_at
CREATE OR REPLACE FUNCTION app.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_config_updated_at
    BEFORE UPDATE ON app.config
    FOR EACH ROW
    EXECUTE FUNCTION app.update_updated_at_column();

-- Vacuum and analyze
VACUUM ANALYZE;
