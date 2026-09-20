import { metrics, trace } from "@opentelemetry/api";
import { OTLPMetricExporter } from "@opentelemetry/exporter-metrics-otlp-proto";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-proto";
import { resourceFromAttributes } from "@opentelemetry/resources";
import { AggregationType, PeriodicExportingMetricReader } from "@opentelemetry/sdk-metrics";
import { NodeSDK } from "@opentelemetry/sdk-node";

export const serviceName = process.env.OTEL_SERVICE_NAME ?? "demo-api";
const serviceNamespace = process.env.OTEL_SERVICE_NAMESPACE ?? "toolbox-observability";
const deploymentEnvironment = process.env.DEPLOYMENT_ENVIRONMENT ?? "local";
const serviceVersion = process.env.OTEL_SERVICE_VERSION ?? "0.1.0";
const otlpEndpoint = (process.env.OTEL_EXPORTER_OTLP_ENDPOINT ?? "http://otel-collector:4318").replace(/\/$/, "");

const sdk = new NodeSDK({
  resource: resourceFromAttributes({
    "service.name": serviceName,
    "service.namespace": serviceNamespace,
    "service.instance.id": process.env.HOSTNAME ?? `${serviceName}-local`,
    "service.version": serviceVersion,
    "deployment.environment.name": deploymentEnvironment,
  }),
  traceExporter: new OTLPTraceExporter({ url: `${otlpEndpoint}/v1/traces` }),
  metricReaders: [
    new PeriodicExportingMetricReader({
      exporter: new OTLPMetricExporter({ url: `${otlpEndpoint}/v1/metrics` }),
      exportIntervalMillis: 10_000,
    }),
  ],
  views: [
    {
      instrumentName: "app.http.server.request.duration",
      aggregation: {
        type: AggregationType.EXPLICIT_BUCKET_HISTOGRAM,
        options: { boundaries: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5], recordMinMax: true },
      },
    },
    {
      instrumentName: "app.db.client.operation.duration",
      aggregation: {
        type: AggregationType.EXPLICIT_BUCKET_HISTOGRAM,
        options: { boundaries: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5], recordMinMax: true },
      },
    },
  ],
});

sdk.start();

export const tracer = trace.getTracer("demo-api", "1.0.0");
export const meter = metrics.getMeter("demo-api", "1.0.0");

export async function shutdownTelemetry(): Promise<void> {
  await sdk.shutdown();
}
