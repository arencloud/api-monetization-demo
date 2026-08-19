package com.arencloud.integration;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.equalTo;

import io.quarkus.test.junit.QuarkusTest;
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
}

