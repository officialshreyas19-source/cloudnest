import uuid

from flask import Flask, jsonify, request

app = Flask(__name__)

APPROVAL_LIMIT = 5000


@app.get("/health")
def health():
    return jsonify(status="ok", service="payment")


@app.post("/pay")
def pay():
    data = request.get_json(silent=True) or {}
    order_id = data.get("order_id")
    amount = data.get("amount")
    valid = (
        isinstance(order_id, int)
        and not isinstance(amount, bool)
        and isinstance(amount, (int, float))
        and amount > 0
    )
    if not valid:
        return jsonify(error="order_id must be a whole number and amount a positive number"), 400
    status = "approved" if amount <= APPROVAL_LIMIT else "declined"
    return jsonify(payment_id=str(uuid.uuid4()), order_id=order_id, amount=amount, status=status)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
