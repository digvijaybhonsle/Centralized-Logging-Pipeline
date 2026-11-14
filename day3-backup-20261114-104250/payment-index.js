import express from "express";

const app = express();
const PORT = process.env.PORT || 3003;

app.use(express.json());

const payments = [];

app.get("/health", (req, res) => {
  res.status(200).json({
    status: "healthy",
    service: "payment-service"
  });
});

app.get("/payments", (req, res) => {
  res.json({
    success: true,
    count: payments.length,
    data: payments
  });
});

app.post("/payments", (req, res) => {
  const { orderId, amount, method } = req.body;

  if (!orderId || typeof amount !== "number" || amount <= 0 || !method) {
    return res.status(400).json({
      success: false,
      message: "Valid orderId, positive amount and method are required"
    });
  }

  const payment = {
    id: Date.now(),
    orderId,
    amount,
    method,
    status: "successful"
  };

  payments.push(payment);

  res.status(201).json({
    success: true,
    data: payment
  });
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`Payment Service running on port ${PORT}`);
});
