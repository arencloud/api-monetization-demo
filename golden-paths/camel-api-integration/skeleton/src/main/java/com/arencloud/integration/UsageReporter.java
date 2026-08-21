package com.arencloud.integration;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Named;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import org.apache.camel.Exchange;
import org.apache.camel.Message;

/** Exports accepted, attributed usage without delaying the consumer response. */
@ApplicationScoped
@Named("usageReporter")
public class UsageReporter {
    private final ObjectMapper mapper = new ObjectMapper();
    private final HttpClient client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build();
    private final String sink = System.getenv().getOrDefault("USAGE_SINK_URL", "");
    private final String product = System.getenv().getOrDefault("MONETIZATION_PRODUCT", "${{ values.name }}");
    private final String unit = System.getenv().getOrDefault("MONETIZATION_UNIT", "request");

    public void record(Exchange exchange) {
        if (sink.isBlank()) return;
        Message message = exchange.getMessage();
        String customer = header(message, "x-monetization-customer");
        if (customer.isBlank()) return;
        int status = message.getHeader(Exchange.HTTP_RESPONSE_CODE, 200, Integer.class);
        long units = status >= 200 && status < 300 ? 1 : 0;
        if (units > 0 && "token".equals(unit)) {
            units = parseUnits(header(message, "X-Monetization-Billable-Units"));
        }
        Map<String, Object> event = new LinkedHashMap<>();
        event.put("requestId", valueOr(header(message, "x-request-id"), exchange.getExchangeId()));
        event.put("customer", customer);
        event.put("plan", header(message, "x-monetization-plan"));
        event.put("product", product);
        event.put("operation", valueOr(message.getHeader(Exchange.HTTP_METHOD, String.class), "POST") + " ${{ values.apiPath }}");
        event.put("occurredAt", Instant.now().toString());
        event.put("statusCode", status);
        event.put("durationMs", 0);
        event.put("requestBytes", 0);
        event.put("responseBytes", 0);
        event.put("billableUnits", units);
        try {
            HttpRequest request = HttpRequest.newBuilder(URI.create(sink))
                .timeout(Duration.ofSeconds(3))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(mapper.writeValueAsString(event)))
                .build();
            client.sendAsync(request, HttpResponse.BodyHandlers.discarding());
        } catch (Exception ignored) {
            // Metering is best effort at request time; the billing sink deduplicates request IDs.
        }
    }

    private static String header(Message message, String name) {
        String value = message.getHeader(name, String.class);
        return value == null ? "" : value;
    }

    private static String valueOr(String value, String fallback) {
        return value == null || value.isBlank() ? fallback : value;
    }

    private static long parseUnits(String value) {
        try {
            long parsed = Long.parseLong(value);
            return Math.max(parsed, 0);
        } catch (NumberFormatException ignored) {
            return 0;
        }
    }
}
