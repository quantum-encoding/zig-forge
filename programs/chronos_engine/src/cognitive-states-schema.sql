-- Cognitive States Database Schema
-- Stores captured cognitive states from Claude Code with deduplication

CREATE TABLE IF NOT EXISTS cognitive_states (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp_ns INTEGER NOT NULL,
    timestamp_human TEXT NOT NULL,
    pid INTEGER NOT NULL,
    process_name TEXT NOT NULL,
    state_type TEXT NOT NULL,  -- 'tool_execution', 'thinking', 'channelling', etc.
    tool_name TEXT,            -- e.g., 'Bash', 'Read', 'Write'
    tool_args TEXT,            -- Full command/args
    status TEXT,               -- 'Running', 'Completed', 'Interrupted', etc.
    raw_content TEXT NOT NULL,
    content_hash TEXT NOT NULL UNIQUE,  -- SHA256 of normalized content for dedup
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_timestamp ON cognitive_states(timestamp_ns);
CREATE INDEX IF NOT EXISTS idx_pid ON cognitive_states(pid);
CREATE INDEX IF NOT EXISTS idx_state_type ON cognitive_states(state_type);
CREATE INDEX IF NOT EXISTS idx_content_hash ON cognitive_states(content_hash);

-- State transitions table (tracks changes over time)
CREATE TABLE IF NOT EXISTS state_transitions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_state_id INTEGER,
    to_state_id INTEGER NOT NULL,
    transition_time_ms INTEGER,  -- Time elapsed between states
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (from_state_id) REFERENCES cognitive_states(id),
    FOREIGN KEY (to_state_id) REFERENCES cognitive_states(id)
);

CREATE INDEX IF NOT EXISTS idx_transition_time ON state_transitions(created_at);

-- Statistics view
CREATE VIEW IF NOT EXISTS cognitive_stats AS
SELECT
    state_type,
    COUNT(*) as occurrence_count,
    AVG(CASE
        WHEN tool_name IS NOT NULL THEN 1
        ELSE 0
    END) * 100 as tool_usage_percent,
    COUNT(DISTINCT DATE(created_at)) as active_days
FROM cognitive_states
GROUP BY state_type
ORDER BY occurrence_count DESC;

-- Session summary view
CREATE VIEW IF NOT EXISTS session_summary AS
SELECT
    DATE(created_at) as session_date,
    COUNT(*) as total_states,
    COUNT(DISTINCT state_type) as unique_states,
    MIN(timestamp_ns) as first_event_ns,
    MAX(timestamp_ns) as last_event_ns,
    (MAX(timestamp_ns) - MIN(timestamp_ns)) / 1000000000.0 as duration_seconds
FROM cognitive_states
GROUP BY DATE(created_at)
ORDER BY session_date DESC;
