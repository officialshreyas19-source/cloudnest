import os

import psycopg2
from flask import Flask, jsonify, request

app = Flask(__name__)
_ready = False


def get_conn():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "cloudnest"),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        sslmode=os.environ.get("DB_SSLMODE", "prefer"),
        connect_timeout=5,
    )


def run(sql, params=None, fetch=False):
    conn = get_conn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(sql, params)
            if fetch:
                return cur.fetchall()
    finally:
        conn.close()


def ensure_table():
    global _ready
    if not _ready:
        run(
            "CREATE TABLE IF NOT EXISTS orders ("
            "id SERIAL PRIMARY KEY, "
            "item_id INTEGER NOT NULL, "
            "quantity INTEGER NOT NULL, "
            "created_at TIMESTAMP DEFAULT now())"
        )
        _ready = True


@app.get("/health")
def health():
    return jsonify(status="ok", service="order")


@app.get("/health/db")
def health_db():
    try:
        run("SELECT 1")
        return jsonify(status="ok", database="reachable")
    except Exception as exc:
        return jsonify(status="error", detail=str(exc)), 503


@app.post("/orders")
def create_order():
    data = request.get_json(silent=True) or {}
    item_id = data.get("item_id")
    quantity = data.get("quantity", 1)
    if not isinstance(item_id, int) or not isinstance(quantity, int) or quantity < 1:
        return jsonify(error="item_id and quantity must be whole numbers"), 400
    ensure_table()
    rows = run(
        "INSERT INTO orders (item_id, quantity) VALUES (%s, %s) RETURNING id",
        (item_id, quantity),
        fetch=True,
    )
    return jsonify(id=rows[0][0], item_id=item_id, quantity=quantity), 201


@app.get("/orders")
def list_orders():
    ensure_table()
    rows = run(
        "SELECT id, item_id, quantity, created_at FROM orders ORDER BY id DESC LIMIT 50",
        fetch=True,
    )
    return jsonify(
        [
            {"id": r[0], "item_id": r[1], "quantity": r[2], "created_at": r[3].isoformat()}
            for r in rows
        ]
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
