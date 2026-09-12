FROM dart:3.11.5@sha256:03b628160f6906098352a6d9c97a147afaa28cf4af97cb588aa33655d6ec3125 AS build

WORKDIR /src
COPY backend/pubspec.* backend/
RUN cd backend && dart pub get

COPY backend backend
COPY abidjantransport-lignes-sotra.csv abidjantransport-lignes-sotra.csv
COPY piwibus_app/assets/maps/cote_divoire_labels.json piwibus_app/assets/maps/cote_divoire_labels.json
RUN cd backend && mkdir -p build && dart compile exe bin/piwibus_backend.dart -o build/piwibus_backend
RUN cd backend && dart compile exe bin/piwibus_healthcheck.dart -o build/piwibus_healthcheck

FROM dart:3.11.5@sha256:03b628160f6906098352a6d9c97a147afaa28cf4af97cb588aa33655d6ec3125 AS runtime

# Containers must not run as root: create a dedicated non-root user.
RUN groupadd -r piwibus && useradd -r -g piwibus -d /app/backend piwibus

WORKDIR /app/backend
COPY --from=build /src/backend/build/piwibus_backend /app/backend/build/piwibus_backend
COPY --from=build /src/backend/build/piwibus_healthcheck /app/backend/build/piwibus_healthcheck
COPY --from=build /src/backend/admin_web /app/backend/admin_web
COPY --from=build /src/backend/data/seed_state.json /app/backend/data/seed_state.json
COPY --from=build /src/abidjantransport-lignes-sotra.csv /app/abidjantransport-lignes-sotra.csv
COPY --from=build /src/piwibus_app/assets/maps/cote_divoire_labels.json /app/backend/assets/maps/cote_divoire_labels.json

ENV PIWIBUS_BACKEND_HOST=0.0.0.0
ENV PIWIBUS_BACKEND_PORT=8080
EXPOSE 8080

# The backend persists state to /app/backend/data/state.json at runtime,
# so the runtime directory must be writable by the non-root user.
RUN mkdir -p /app/backend/data && chown -R piwibus:piwibus /app/backend

USER piwibus

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/app/backend/build/piwibus_healthcheck"]

ENTRYPOINT ["/app/backend/build/piwibus_backend"]
