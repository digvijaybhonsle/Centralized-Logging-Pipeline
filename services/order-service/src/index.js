import express from "express";
import crypto from "node:crypto";
import pino from "pino";
import pinoHttp from "pino-http";

const app = express();
const PORT = process.env.PORT || 3002;
const SERVICE_NAME = "order-service";
const USER_SERVICE_URL =
  process.env.USER_SERVICE_URL || "http://user-service:3001";

const streams = pino.multistream([
  { stream: process.stdout },
  {
    stream: pino.destination({
      dest: process.env.LOG_FILE || "/var/log/app/order-service.json",
      sync: true
    })
  }
]);

const logger = pino({ level: process.env.LOG_LEVEL || "info" }, streams);

app.use(express.json());

app.use(pinoHttp({
  logger,
  genReqId(req, res) {
    const incoming = req.headers["x-request-id"];
    const requestId =
      typeof incoming === "string" &&
      incoming.trim().length > 0 &&
      incoming.length <= 128
        ? incoming
        : crypto.randomUUID();

    res.setHeader("X-Request-ID", requestId);
    return requestId;
  },
  customProps(req) {
    return {
      service: SERVICE_NAME,
      requestId: req.id,
      traceId: req.id
    };
  },
  serializers: {
    req(req) {
      return {
        method: req.method,
        url: req.url
      };
    },
    res(res) {
      return {
        statusCode: res.statusCode
      };
    }
  }
}));

const orders = [
  { id: 101, userId: 1, product: "Laptop", amount: 55000, status: "created" },
  { id: 102, userId: 2, product: "Keyboard", amount: 2500, status: "created" }
];

app.get("/health", (req, res) => {
  res.status(200).json({
    status: "healthy",
    service: SERVICE_NAME
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
    req.log.warn({ orderId: req.params.id }, "Order not found");

    return res.status(404).json({
      success: false,
      message: "Order not found"
    });
  }

  res.json({ success: true, data: order });
});

app.post("/orders", async (req, res) => {
  const { userId, product, amount } = req.body;

  if (!userId || !product || typeof amount !== "number" || amount <= 0) {
    return res.status(400).json({
      success: false,
      message: "Valid userId, product and positive amount are required"
    });
  }

  let userResponse;

  try {
    userResponse = await fetch(
      `${USER_SERVICE_URL}/users/${encodeURIComponent(userId)}`,
      {
        headers: {
          "X-Request-ID": req.id
        },
        signal: AbortSignal.timeout(5000)
      }
    );
  } catch (err) {
    req.log.error({ err, userId }, "User service request failed");

    return res.status(502).json({
      success: false,
      message: "Unable to validate user with user-service"
    });
  }

  if (!userResponse.ok) {
    req.log.warn(
      { userId, downstreamStatus: userResponse.status },
      "Order rejected because user validation failed"
    );

    return res.status(400).json({
      success: false,
      message: "User does not exist"
    });
  }

  req.log.info({ userId }, "User validated by user-service");

  const order = {
    id: Date.now(),
    userId,
    product,
    amount,
    status: "created"
  };

  orders.push(order);

  req.log.info(
    { orderId: order.id, userId, amount },
    "Order created"
  );

  res.status(201).json({
    success: true,
    data: order
  });
});

app.listen(PORT, "0.0.0.0", () => {
  logger.info({ port: PORT }, "Order service started");
});
