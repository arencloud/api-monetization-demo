package com.arencloud.integration;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Named;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

@ApplicationScoped
@Named("canonicalMapping")
public class CanonicalMapping {

    public Map<String, Object> map(Map<String, Object> source) {
        Map<String, Object> canonical = new LinkedHashMap<>();
        canonical.put("interface", "${{ values.name }}");
        canonical.put("correlationId", source.getOrDefault("correlationId", "not-provided"));
        canonical.put("payload", source.getOrDefault("payload", source));
        canonical.put("mappedAt", Instant.now().toString());
        return canonical;
    }
}

