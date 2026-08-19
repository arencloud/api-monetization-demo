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

/** Serves the API contract on the mesh-exempt documentation-only port. */
@ApplicationScoped
public class OpenApiDocumentationServer {
    private HttpServer server;
    private byte[] specification;

    void start(@Observes StartupEvent ignored) throws IOException {
        try (InputStream stream = Thread.currentThread().getContextClassLoader()
                .getResourceAsStream("META-INF/resources/openapi.yaml")) {
            if (stream == null) {
                throw new IOException("openapi.yaml is missing from the application");
            }
            specification = stream.readAllBytes();
        }
        int port = Integer.parseInt(System.getenv().getOrDefault("DOCS_PORT", "8082"));
        server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/healthz", exchange -> respond(exchange, "text/plain", "ok\n".getBytes(StandardCharsets.UTF_8)));
        server.createContext("/openapi.yaml", exchange -> respond(exchange, "application/yaml", specification));
        server.start();
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
