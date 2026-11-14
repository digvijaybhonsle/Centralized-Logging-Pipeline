import express from "express";
import crypto from "node:crypto";
import pino from "pino";
import pinoHttp from "pino-http";

const app = express();
const PORT = process.env.PORT || 3003;
const SERVICE_NAME = "payment-service";

const streams = pino.multistream([
  { stream: process.stdout },
  {
    stream: pino.destination({
      dest: process.env.LOG_FILE || "/var/log/app/payment-service.json",
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

const payments = [];

app.get("/health", (req, res) => {
  res.status(200).json({
    status: "healthy",
    service: SERVICE_NAME
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

  req.log.info(
    { paymentId: payment.id, orderId, amount, method },
    "Payment processed"
  );

  res.status(201).json({
    success: true,
    data: payment
  });
});

app.listen(PORT, "0.0.0.0", () => {
  logger.info({ port: PORT }, "Payment service started");
});
