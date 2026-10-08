from flask import Flask, jsonify

app = Flask(__name__)

MENU = [
    {"id": 1, "name": "Margherita Pizza", "price": 249},
    {"id": 2, "name": "Veg Burger", "price": 129},
    {"id": 3, "name": "Paneer Wrap", "price": 149},
    {"id": 4, "name": "Masala Dosa", "price": 99},
]


@app.get("/health")
def health():
    return jsonify(status="ok", service="menu")


@app.get("/menu")
def list_menu():
    return jsonify(MENU)


@app.get("/menu/<int:item_id>")
def get_item(item_id):
    for item in MENU:
        if item["id"] == item_id:
            return jsonify(item)
    return jsonify(error="item not found"), 404


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
