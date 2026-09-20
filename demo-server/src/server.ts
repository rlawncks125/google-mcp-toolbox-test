import { context, propagation, SpanKind, SpanStatusCode, trace, type Attributes } from "@opentelemetry/api";
import { MongoClient } from "mongodb";
import { Pool } from "pg";
import { createClient } from "redis";
import { meter, serviceName, shutdownTelemetry, tracer } from "./telemetry";

const port = Number(process.env.PORT ?? 3001);
const dbName = process.env.DB_NAME ?? "app";
const mongoDatabase = process.env.MONGO_DATABASE ?? "app";

const postgres = new Pool({
  host: process.env.DB_HOST ?? "postgres",
  port: Number(process.env.DB_PORT ?? 5432),
  database: dbName,
  user: process.env.APP_DB_USER ?? "demo_app",
  password: process.env.APP_DB_PASSWORD ?? "local-demo-app-change-me",
  application_name: serviceName,
  max: 10,
});

const redis = createClient({
  url: `redis://:${encodeURIComponent(process.env.REDIS_PASSWORD ?? "local-redis-change-me")}@${process.env.REDIS_HOST ?? "redis"}:${process.env.REDIS_PORT ?? "6379"}`,
});

const mongo = new MongoClient(
  `mongodb://${encodeURIComponent(process.env.MONGO_APP_USER ?? "demo_app")}:${encodeURIComponent(process.env.MONGO_APP_PASSWORD ?? "local-demo-mongo-change-me")}@${process.env.MONGO_HOST ?? "mongodb"}:${process.env.MONGO_PORT ?? "27017"}/${mongoDatabase}?authSource=${mongoDatabase}`,
  { appName: serviceName },
);

const httpDuration = meter.createHistogram("app.http.server.request.duration", {
  description: "Demo API server request duration",
  unit: "s",
});
const dbDuration = meter.createHistogram("app.db.client.operation.duration", {
  description: "Demo API database client operation duration",
  unit: "s",
});
const requestCount = meter.createCounter("app.http.server.request.count", {
  description: "Demo API server request count",
});

function log(event: string, fields: Record<string, unknown> = {}): void {
  const spanContext = trace.getActiveSpan()?.spanContext();
  console.log(JSON.stringify({
    timestamp: new Date().toISOString(),
    severity: "INFO",
    service: serviceName,
    event,
    trace_id: spanContext?.traceId,
    span_id: spanContext?.spanId,
    ...fields,
  }));
}

async function withDbSpan<T>(
  spanName: string,
  attributes: Attributes,
  operation: () => Promise<T>,
): Promise<T> {
  const startedAt = performance.now();
  return tracer.startActiveSpan(spanName, { kind: SpanKind.CLIENT, attributes }, async (span) => {
    try {
      return await operation();
    } catch (error) {
      span.recordException(error as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (error as Error).message });
      throw error;
    } finally {
      dbDuration.record((performance.now() - startedAt) / 1000, {
        "db.system.name": attributes["db.system.name"] as string,
        "db.operation.name": attributes["db.operation.name"] as string,
        "db.query.summary": attributes["db.query.summary"] as string,
      });
      span.end();
    }
  });
}

async function findOrders(customer: string, delayMs: number) {
  const result = await withDbSpan(
    "SELECT demo.orders",
    {
      "db.system.name": "postgresql",
      "db.namespace": dbName,
      "db.operation.name": "SELECT",
      "db.collection.name": "demo.orders",
      "db.query.summary": "SELECT demo.orders by customer",
      "server.address": process.env.DB_HOST ?? "postgres",
      "server.port": Number(process.env.DB_PORT ?? 5432),
    },
    () => postgres.query(
      `SELECT o.id, o.customer_name, o.total_cents, o.status, o.created_at
         FROM demo.orders AS o
         CROSS JOIN LATERAL (SELECT pg_sleep($2::double precision)) AS delay
        WHERE o.customer_name = $1
        ORDER BY o.created_at DESC
        LIMIT 20`,
      [customer, delayMs / 1000],
    ),
  );
  return result.rows;
}

async function readCache(cacheKey: string) {
  const attributes = {
    "db.system.name": "redis",
    "db.namespace": "0",
    "db.operation.name": "GET",
    "db.query.summary": "GET demo response cache",
    "server.address": process.env.REDIS_HOST ?? "redis",
    "server.port": Number(process.env.REDIS_PORT ?? 6379),
  };
  let value = await withDbSpan("GET redis cache", attributes, () => redis.get(cacheKey));
  if (value === null) {
    value = JSON.stringify({ generatedAt: new Date().toISOString(), source: "demo-api" });
    await withDbSpan(
      "SET redis cache",
      { ...attributes, "db.operation.name": "SET", "db.query.summary": "SET demo response cache" },
      () => redis.set(cacheKey, value!, { EX: 60 }),
    );
  }
  return JSON.parse(value);
}

async function recentEvents(limit: number) {
  return withDbSpan(
    "find app.health_events",
    {
      "db.system.name": "mongodb",
      "db.namespace": mongoDatabase,
      "db.operation.name": "find",
      "db.collection.name": "health_events",
      "db.query.summary": "find recent health_events",
      "server.address": process.env.MONGO_HOST ?? "mongodb",
      "server.port": Number(process.env.MONGO_PORT ?? 27017),
    },
    () => mongo.db(mongoDatabase).collection("health_events")
      .find({}, { projection: { _id: 0 } })
      .sort({ createdAt: -1 })
      .limit(limit)
      .toArray(),
  );
}

function routeFor(request: Request, url: URL): string | undefined {
  if (request.method === "GET" && url.pathname === "/health") return "/health";
  if (request.method === "GET" && url.pathname === "/api/postgres/orders") return "/api/postgres/orders";
  if (request.method === "GET" && url.pathname.startsWith("/api/redis/cache/")) return "/api/redis/cache/:key";
  if (request.method === "GET" && url.pathname === "/api/mongodb/events") return "/api/mongodb/events";
  if (request.method === "GET" && url.pathname === "/api/combined") return "/api/combined";
  return undefined;
}

function json(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  return Response.json(body, { status, headers });
}

async function handleRequest(request: Request, url: URL, route: string): Promise<Response> {
  if (route === "/health") {
    return json({ status: "ok", service: serviceName });
  }

  const delayMs = Math.min(Math.max(Number(url.searchParams.get("delayMs") ?? 0), 0), 2_000);
  const customer = url.searchParams.get("customer") ?? "alice";

  if (route === "/api/postgres/orders") {
    return json({ orders: await findOrders(customer, delayMs) });
  }
  if (route === "/api/redis/cache/:key") {
    const key = url.pathname.slice("/api/redis/cache/".length) || "default";
    return json({ key, value: await readCache(`demo:${key}`) });
  }
  if (route === "/api/mongodb/events") {
    const limit = Math.min(Math.max(Number(url.searchParams.get("limit") ?? 10), 1), 100);
    return json({ events: await recentEvents(limit) });
  }

  const [orders, cached, events] = await Promise.all([
    findOrders(customer, delayMs),
    readCache("demo:combined"),
    recentEvents(10),
  ]);
  return json({ orders, cached, events });
}

await Promise.all([
  postgres.query("SELECT 1"),
  redis.connect(),
  mongo.connect(),
]);

const server = Bun.serve({
  hostname: "0.0.0.0",
  port,
  async fetch(request) {
    const startedAt = performance.now();
    const url = new URL(request.url);
    const route = routeFor(request, url);
    const parentContext = propagation.extract(context.active(), Object.fromEntries(request.headers.entries()));

    return context.with(parentContext, () => tracer.startActiveSpan(
      `${request.method} ${route ?? "unmatched"}`,
      {
        kind: SpanKind.SERVER,
        attributes: {
          "http.request.method": request.method,
          "http.route": route ?? "unmatched",
          "url.path": url.pathname,
          "server.address": url.hostname,
          "server.port": port,
        },
      },
      async (span) => {
        let status = 200;
        try {
          const response = route
            ? await handleRequest(request, url, route)
            : json({ error: "not_found" }, 404);
          status = response.status;
          span.setAttribute("http.response.status_code", status);
          response.headers.set("x-trace-id", span.spanContext().traceId);
          return response;
        } catch (error) {
          status = 500;
          span.recordException(error as Error);
          span.setStatus({ code: SpanStatusCode.ERROR, message: (error as Error).message });
          span.setAttribute("http.response.status_code", status);
          return json({ error: "internal_server_error", traceId: span.spanContext().traceId }, status, {
            "x-trace-id": span.spanContext().traceId,
          });
        } finally {
          const durationSeconds = (performance.now() - startedAt) / 1000;
          const metricAttributes = {
            "http.request.method": request.method,
            "http.route": route ?? "unmatched",
            "http.response.status_code": status,
          };
          requestCount.add(1, metricAttributes);
          httpDuration.record(durationSeconds, metricAttributes);
          log("request.complete", { method: request.method, route: route ?? "unmatched", status, duration_ms: durationSeconds * 1000 });
          span.end();
        }
      },
    ));
  },
});

log("server.started", { port: server.port });

async function shutdown(): Promise<void> {
  log("server.stopping");
  server.stop();
  await Promise.allSettled([postgres.end(), redis.quit(), mongo.close()]);
  await shutdownTelemetry();
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
