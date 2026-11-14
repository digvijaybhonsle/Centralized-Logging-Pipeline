import express from "express";

const app = express();
const PORT = process.env.PORT || 3002;

app.use(express.json());

const orders = [
  { id: 101, userId: 1, product: "Laptop", amount: 55000, status: "created" },
  { id: 102, userId: 2, product: "Keyboard", amount: 2500, status: "created" }
];

app.get("/health", (req, res) => {
  res.status(200).json({
    status: "healthy",
    service: "order-service"
  });
});

app.get("/orders", (req, res) => {
  res.json({
    success: true,
    count: orders.length,
    data: orders
  });
});

app.get("/orders/:id", (req, res) => {
  const order = orders.find(
    (item) => item.id === Number(req.params.id)
  );

  if (!order) {
    return res.status(404).json({
      success: false,
      message: "Order not found"
    });
  }

  res.json({ success: true, data: order });
});

app.post("/orders", (req, res) => {
  const { userId, product, amount } = req.body;

  if (!userId || !product || typeof amount !== "number" || amount <= 0) {
    return res.status(400).json({
      success: false,
      message: "Valid userId, product and positive amount are required"
    });
  }

  const order = {
    id: Date.now(),
    userId,
    product,
    amount,
    status: "created"
  };

  orders.push(order);

  res.status(201).json({
    success: true,
    data: order
  });
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`Order Service running on port ${PORT}`);
});
