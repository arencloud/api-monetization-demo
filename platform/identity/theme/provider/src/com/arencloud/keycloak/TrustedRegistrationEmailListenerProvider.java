package com.arencloud.keycloak;

import org.keycloak.events.Event;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventType;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

/**
 * Marks email as trusted only after Keycloak completes its local registration
 * flow. This is intentionally a demo profile: production must verify ownership
 * through SMTP instead of trusting an address supplied on a form.
 */
public final class TrustedRegistrationEmailListenerProvider
        implements EventListenerProvider {

    private final KeycloakSession session;

    public TrustedRegistrationEmailListenerProvider(KeycloakSession session) {
        this.session = session;
    }

    @Override
    public void onEvent(Event event) {
        if (event == null || event.getType() != EventType.REGISTER
                || event.getRealmId() == null || event.getUserId() == null) {
            return;
        }

        RealmModel realm = session.realms().getRealm(event.getRealmId());
        if (realm == null || !"api-monetization".equals(realm.getName())) {
            return;
        }

        UserModel user = session.users().getUserById(realm, event.getUserId());
        if (user != null && user.getEmail() != null && !user.getEmail().isBlank()) {
            user.setEmailVerified(true);
        }
    }

    @Override
    public void onEvent(AdminEvent event, boolean includeRepresentation) {
        // Administrator-created and imported identities keep their explicit
        // email verification state.
    }

    @Override
    public void close() {
        // No resources are held by this request-scoped listener.
    }
}
