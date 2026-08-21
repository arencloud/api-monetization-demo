package com.arencloud.integration;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.equalTo;

import io.quarkus.test.junit.QuarkusTest;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;

@QuarkusTest
class MappingRouteTest {

    @Test
    void mapsPartnerPayloadToCanonicalModel() {
        given()
            .contentType("application/json")
            .body("{\"correlationId\":\"order-42\",\"payload\":{\"amount\":49}}")
        .when()
            .post("${{ values.apiPath }}")
        .then()
            .statusCode(200)
            .body("interface", equalTo("${{ values.name }}"))
            .body("correlationId", equalTo("order-42"))
            .body("payload.amount", equalTo(49));
    }

    @Test
    void publishesAuthenticationSpecificOpenApiContracts() throws IOException {
        String apiKey = resource("META-INF/resources/openapi-api-key.yaml");
        String jwt = resource("META-INF/resources/openapi-keycloak-jwt.yaml");
        org.junit.jupiter.api.Assertions.assertTrue(apiKey.contains("type: apiKey"));
        org.junit.jupiter.api.Assertions.assertFalse(apiKey.contains("scheme: bearer"));
        org.junit.jupiter.api.Assertions.assertTrue(jwt.contains("scheme: bearer"));
        org.junit.jupiter.api.Assertions.assertTrue(jwt.contains("bearerFormat: JWT"));
        org.junit.jupiter.api.Assertions.assertFalse(jwt.contains("type: apiKey"));
    }

    @Test
    void acceptsBrowserPreflight() {
        given()
        .when()
            .options("${{ values.apiPath }}")
        .then()
            .statusCode(204);
    }

    private static String resource(String name) throws IOException {
        try (var stream = Thread.currentThread().getContextClassLoader().getResourceAsStream(name)) {
            org.junit.jupiter.api.Assertions.assertNotNull(stream, name + " is missing");
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
