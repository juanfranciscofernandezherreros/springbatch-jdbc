#!/usr/bin/env bash
set -Eeuo pipefail

# Inserta por tramos con generate_series en PostgreSQL. No usa RAM de Java.
# USO: ./scripts/seed.sh 100000 (prueba); ./scripts/seed.sh 10000000 (carga completa)
TOTAL="${1:-100000}"
BLOCK="${SEED_BATCH_SIZE:-50000}"
if ! [[ "$TOTAL" =~ ^[0-9]+$ && "$BLOCK" =~ ^[0-9]+$ ]] || (( TOTAL < 1 || BLOCK < 1 )); then
  echo "Uso: ./scripts/seed.sh NUM_REGISTROS (entero positivo); SEED_BATCH_SIZE > 0" >&2
  exit 2
fi

for (( from=1; from<=TOTAL; from+=BLOCK )); do
  to=$(( from + BLOCK - 1 ))
  (( to > TOTAL )) && to="$TOTAL"
  docker compose exec -T db psql -v ON_ERROR_STOP=1 -U batch -d batchdb -c "
    INSERT INTO source_events (id, customer_id, amount, category, created_at)
    SELECT
      s,
      (s % 100000) + 1,
      ((s % 200000)::numeric / 100),
      CASE (s % 3) WHEN 0 THEN 'retail' WHEN 1 THEN 'subscription' ELSE 'online' END,
      TIMESTAMPTZ '2026-01-01 00:00:00+00' + ((s % 86400) * INTERVAL '1 second')
    FROM generate_series(${from}, ${to}) AS s
    ON CONFLICT (id) DO NOTHING;
  " > /dev/null
  echo "Sembrados IDs ${from}..${to} / ${TOTAL}"
done
