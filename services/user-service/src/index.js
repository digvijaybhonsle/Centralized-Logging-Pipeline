import express from "express";
import crypto from "node:crypto";
import pino from "pino";
import pinoHttp from "pino-http";

const app = express();
const PORT = process.env.PORT || 3001;
const SERVICE_NAME = "user-service";

const streams = pino.multistream([
  { stream: process.stdout },
  {
    stream: pino.destination({
      dest: process.env.LOG_FILE || "/var/log/app/user-service.json",
      sync: true
    })
  }
]);

const logger = pino({
  level: process.env.LOG_LEVEL || "info",
  redact: {
    paths: [
      "password",
      "*.password",
      "email",
      "*.email",
      "phone",
      "*.phone",
      "mobile",
      "*.mobile",
      "authorization",
      "headers.authorization",
      "req.headers.authorization",
      "cookie",
      "headers.cookie",
      "req.headers.cookie",
      "accessToken",
      "*.accessToken",
      "refreshToken",
      "*.refreshToken",
      "token",
      "*.token",
      "apiKey",
      "*.apiKey",
      "secret",
      "*.secret",
      "cardNumber",
      "*.cardNumber",
      "cvv",
      "*.cvv",
      "ssn",
      "*.ssn"
    ],
    censor: "[REDACTED]"
  }
}, streams);

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
        url: req.url.split('?')[0]
      };
    },
    res(res) {
      return {
        statusCode: res.statusCode
      };
    }
  }
}));

const users = [
  { id: 1, name: "Digvijay", email: "digvijay@example.com" },
  { id: 2, name: "Rahul", email: "rahul@example.com" }
];

app.get("/health", (req, res) => {
  res.status(200).json({
    status: "healthy",
    service: SERVICE_NAME
  });
});

app.get("/users", (req, res) => {
  req.log.info({ userCount: users.length }, "Users list requested");

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
    req.log.warn({ userId: req.params.id }, "User not found");

    return res.status(404).json({
      success: false,
      message: "User not found"
    });
  }

  req.log.info({ userId: user.id }, "User fetched");

  res.json({ success: true, data: user });
});

app.listen(PORT, "0.0.0.0", () => {
  logger.info({ port: PORT }, "User service started");
});
