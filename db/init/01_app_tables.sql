-- Tablas de ejemplo. Solo se crea al inicializar un volumen PostgreSQL vacío.
CREATE TABLE source_events (
    id BIGINT PRIMARY KEY,
    customer_id BIGINT NOT NULL,
    amount NUMERIC(12, 2) NOT NULL,
    category VARCHAR(50) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE processed_events (
    id BIGINT PRIMARY KEY,
    customer_id BIGINT NOT NULL,
    amount NUMERIC(12, 2) NOT NULL,
    category VARCHAR(50) NOT NULL,
    amount_band VARCHAR(10) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE rejected_events (
    event_id BIGINT PRIMARY KEY,
    reason VARCHAR(1000) NOT NULL,
    rejected_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
