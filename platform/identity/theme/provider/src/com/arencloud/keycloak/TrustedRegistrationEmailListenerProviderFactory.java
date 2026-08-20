package com.arencloud.keycloak;

import org.keycloak.Config;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventListenerProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

public final class TrustedRegistrationEmailListenerProviderFactory
        implements EventListenerProviderFactory {

    public static final String ID = "trusted-registration-email";

    @Override
    public EventListenerProvider create(KeycloakSession session) {
        return new TrustedRegistrationEmailListenerProvider(session);
    }

    @Override
    public void init(Config.Scope config) {
        // No configurable state.
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // No post-initialization work.
    }

    @Override
    public void close() {
        // No resources are held by the singleton factory.
    }

    @Override
    public String getId() {
        return ID;
    }
}
