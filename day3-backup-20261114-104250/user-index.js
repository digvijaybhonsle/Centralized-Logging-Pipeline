import express from "express";

const app = express();
const PORT = process.env.PORT || 3001;

app.use(express.json());

const users = [
  { id: 1, name: "Digvijay", email: "digvijay@example.com" },
  { id: 2, name: "Rahul", email: "rahul@example.com" }
];

app.get("/health", (req, res) => {
  res.status(200).json({
    status: "healthy",
    service: "user-service"
  });
});

app.get("/users", (req, res) => {
  res.status(200).json({
    success: true,
    count: users.length,
    data: users
  });
});

app.get("/users/:id", (req, res) => {
  const user = users.find(
    (item) => item.id === Number(req.params.id)
  );

  if (!user) {
    return res.status(404).json({
      success: false,
      message: "User not found"
    });
  }

  res.json({ success: true, data: user });
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`User Service running on port ${PORT}`);
});
