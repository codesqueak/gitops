# Developer Guide

## Purpose

This guide describes the changes required in Spring Boot 4 services to integrate with the observability platform.

## Dependencies

Gradle:

```gradle
dependencies {
    implementation "org.springframework.boot:spring-boot-starter-actuator"
    implementation "org.springframework.boot:spring-boot-starter-opentelemetry"
    implementation "net.logstash.logback:logstash-logback-encoder:9.0"
}
```

## application.properties

```properties
spring.application.name=customer-service

management.endpoint.health.probes.enabled=true
management.endpoints.web.exposure.include=health,info,metrics

management.opentelemetry.resource-attributes.service.name=${spring.application.name}
management.opentelemetry.resource-attributes.service.namespace=codesqueak
management.opentelemetry.resource-attributes.deployment.environment=${ENVIRONMENT:dev}

management.otlp.metrics.export.enabled=true
management.otlp.metrics.export.url=http://alloy.observability.svc.cluster.local:4318/v1/metrics
management.metrics.tags.application=${spring.application.name}

management.otlp.tracing.endpoint=http://alloy.observability.svc.cluster.local:4318/v1/traces

# Default sampling is 10% (management.tracing.sampling.probability=0.1) — most log lines
# would have no trace_id/span_id. Set to 1.0 for low-traffic dev/staging services; tune
# down for high-throughput production services once traffic volume is known.
management.tracing.sampling.probability=1.0
```

`management.metrics.tags.application` is what the JVM (Micrometer) dashboard's app picker filters on - without
it the picker resolves to empty even though metrics are flowing. See
[install-observability.md](install-observability.md#dashboard-fixes) for the full story.

`management.endpoint.health.probes.enabled` and `management.otlp.metrics.export.enabled` both default to
`true` already (Spring Boot enables health probes automatically once it detects it's running on Kubernetes,
and the OTLP metrics exporter is enabled by default once the dependency is on the classpath) - setting them
explicitly here is belt-and-braces, not strictly required, but keeps behavior from silently changing if the
app is ever run somewhere that isn't detected as Kubernetes (e.g. plain `docker run`/docker-compose).

## Kubernetes Configuration

`motd`'s chart (`gitops-repo/charts/motd/values.yaml`) only sets `SPRING_PROFILES_ACTIVE`, not `ENVIRONMENT`:

```yaml
env:
  - name: SPRING_PROFILES_ACTIVE
    value: "prod"
```

Because of this, `${ENVIRONMENT:dev}` above always falls back to its default - `deployment.environment` and
the logback `environment` field both report `dev` in every environment today, regardless of Spring profile.
If a service needs `deployment.environment` to reflect its actual deployment tier (staging/prod, etc.), add
an explicit `ENVIRONMENT` env var to that service's chart values - this project just doesn't do so yet, since
everything currently only runs in `dev`.

### How env vars bind to Spring config

Charts configure Spring Boot purely through env vars - no mounted `application.yml`, no `-D` flags. Two
different binding paths apply depending on the property being set:

- **Plain, flat properties** (`spring.application.name`, `spring.profiles.active`,
  `management.tracing.sampling.probability`, etc.) bind directly via Spring's relaxed `SCREAMING_SNAKE_CASE`
  convention - `SPRING_PROFILES_ACTIVE=prod` maps straight onto `spring.profiles.active`. This is reliable
  for any single-value property and is what every env var in this guide uses except one.

- **`Map`-typed properties whose keys are dynamic and dotted are not reliable to set this way.** Relaxed
  binding has to guess where an env var's underscores become dots vs. dashes, and for some properties that
  guess is genuinely ambiguous - most notably `management.metrics.distribution.percentiles-histogram.<meter-id>`
  (`Map<String, Boolean>`), whose name is a word-prefix of the sibling `management.metrics.distribution.percentiles.<meter-id>`
  (`Map<String, double[]>`). Setting `MANAGEMENT_METRICS_DISTRIBUTION_PERCENTILES_HISTOGRAM_HTTP_SERVER_REQUESTS=true`
  actually binds into the wrong property and crashes the app on boot (`UnsatisfiedDependencyException`,
  trying to convert `"true"` into a `double[]`) - this happened for real in `motd`; see
  [install-observability.md](install-observability.md#how-motds-two-env-vars-reach-spring-boot-config) for
  the full incident. Other properties in the same risk class: `management.metrics.tags.*`,
  `logging.level.*`, `spring.jpa.properties.*` - anywhere the map's keys are meter IDs, logger names, or
  other dotted identifiers the app doesn't control.

  For these, set `SPRING_APPLICATION_JSON` instead of individual env vars. Spring Boot's
  `SpringApplicationJsonEnvironmentPostProcessor` parses it as literal JSON - preserving dots/dashes in keys
  exactly as written - and installs it as a high-precedence `PropertySource` before relaxed env-var binding
  ever gets a chance to misparse a key:

  ```yaml
  env:
    - name: SPRING_APPLICATION_JSON
      value: '{"management":{"metrics":{"distribution":{"percentiles-histogram":{"http.server.requests":true}}}}}'
  ```

  If in doubt whether a property you're adding falls into the risky bucket: check whether its target type is
  a `Map` with keys the app doesn't control. If so, use `SPRING_APPLICATION_JSON`, not a plain env var.

## Health Probes

Use whichever port the service actually listens on (see [port-usage.md](port-usage.md) for the allocated
port per service - `motd` is `8000`, not the Spring Boot default of `8080`):

```yaml
readinessProbe:
  httpGet:
    path: /actuator/health/readiness
    port: 8000

livenessProbe:
  httpGet:
    path: /actuator/health/liveness
    port: 8000
```

## Structured Logging

Log JSON to stdout.

Recommended fields:

- timestamp
- level
- service
- environment
- trace_id
- span_id
- logger
- thread
- message

Add `src/main/resources/logback-spring.xml`. Spring's tracing autoconfiguration (from `spring-boot-starter-opentelemetry`) populates SLF4J MDC with `traceId`/`spanId` (camelCase) for the duration of an active span — the `pattern` provider below reads those MDC keys and re-emits them under the `trace_id`/`span_id` field names listed above. MDC keys are empty outside a request/span context (e.g. startup logs), so `trace_id`/`span_id` will legitimately be blank there.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <springProperty scope="context" name="serviceName" source="spring.application.name"/>
    <springProperty scope="context" name="environment" source="ENVIRONMENT" defaultValue="dev"/>

    <appender name="STDOUT" class="ch.qos.logback.core.ConsoleAppender">
        <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
            <providers>
                <timestamp/>
                <logLevel>
                    <fieldName>level</fieldName>
                </logLevel>
                <loggerName>
                    <fieldName>logger</fieldName>
                </loggerName>
                <threadName>
                    <fieldName>thread</fieldName>
                </threadName>
                <message/>
                <stackTrace/>
                <pattern>
                    <pattern>
                        {
                          "service": "${serviceName}",
                          "environment": "${environment}",
                          "trace_id": "%mdc{traceId:-}",
                          "span_id": "%mdc{spanId:-}"
                        }
                    </pattern>
                </pattern>
            </providers>
        </encoder>
    </appender>

    <root level="INFO">
        <appender-ref ref="STDOUT"/>
    </root>
</configuration>
```

This has been verified end-to-end in the `motd` service: hitting an endpoint produces log lines with real `trace_id`/`span_id` values, e.g. `{"trace_id":"90caf4931b79e01e244c76339d75415e","span_id":"b2320ab4beda412b", ...}`.

## Business Metrics

Use Micrometer.

Example metrics:

- receipts.processed
- receipts.failed
- offers.generated
- offers.failed
- till.requests
- till.failures

Good metric tags:

- service
- environment
- channel
- region
- result

Avoid:

- user_id
- request_id
- receipt_id
- basket_id
- email

## Tracing

Ensure trace_id and span_id are present in logs.

This enables:

```text
Metrics -> Traces -> Logs
```

## Developer Checklist

- Actuator enabled
- OpenTelemetry enabled
- Service name configured
- Health probes configured
- JSON logging configured
- Trace IDs present in logs
- Business metrics implemented where appropriate
