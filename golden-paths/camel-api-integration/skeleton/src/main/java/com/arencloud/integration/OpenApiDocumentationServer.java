package com.arencloud.integration;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.quarkus.runtime.ShutdownEvent;
import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import java.io.IOException;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/** Serves the API contract on the mesh-exempt documentation-only port. */
@ApplicationScoped
public class OpenApiDocumentationServer {
    private HttpServer server;
    private Map<String, byte[]> specifications;

    void start(@Observes StartupEvent ignored) throws IOException {
        byte[] apiKey = loadSpecification(
                "META-INF/resources/openapi-api-key.yaml",
                "API_KEY_BASE_URL",
                "https://api.example.invalid");
        byte[] keycloakJwt = loadSpecification(
                "META-INF/resources/openapi-keycloak-jwt.yaml",
                "JWT_BASE_URL",
                "https://jwt.api.example.invalid");
        specifications = Map.of(
                "/openapi.yaml", apiKey,
                "/openapi/api-key.yaml", apiKey,
                "/openapi/keycloak-jwt.yaml", keycloakJwt);
        int port = Integer.parseInt(System.getenv().getOrDefault("DOCS_PORT", "8082"));
        server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/healthz", exchange -> respond(exchange, "text/plain", "ok\n".getBytes(StandardCharsets.UTF_8)));
        specifications.forEach((path, body) ->
                server.createContext(path, exchange -> respond(exchange, "application/yaml", body)));
        server.start();
    }

    private static byte[] loadSpecification(String resource, String environmentName, String placeholder)
            throws IOException {
        try (InputStream stream = Thread.currentThread().getContextClassLoader().getResourceAsStream(resource)) {
            if (stream == null) {
                throw new IOException(resource + " is missing from the application");
            }
            String source = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
            String endpoint = System.getenv().getOrDefault(environmentName, placeholder);
            return source.replace(placeholder, endpoint).getBytes(StandardCharsets.UTF_8);
        }
    }

    void stop(@Observes ShutdownEvent ignored) {
        if (server != null) {
            server.stop(1);
        }
    }

    private static void respond(HttpExchange exchange, String contentType, byte[] body) throws IOException {
        if (!"GET".equals(exchange.getRequestMethod())) {
            exchange.sendResponseHeaders(405, -1);
            exchange.close();
            return;
        }
        exchange.getResponseHeaders().set("Content-Type", contentType);
        exchange.sendResponseHeaders(200, body.length);
        try (var response = exchange.getResponseBody()) {
            response.write(body);
        }
    }
}
