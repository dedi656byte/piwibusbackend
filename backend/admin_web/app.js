const state = {
  csrfToken: "",
  dashboard: null,
  eventSource: null,
  socket: null,
  stopTripId: "",
  stopTripLabel: "",
  expandedTrips: new Set(),
  mapCatalog: null,
  mapCatalogLoading: false,
  mapSelectedLine: "",
  mapShowUsers: true,
  mapUserRadiusMeters: 1000,
  mapMarkers: [],
  mapTileCache: new Map(),
  mapTilesVisible: true,
  mapZoomDelta: 0,
  mapCurrentZoom: 8,
  mapPanX: 0,
  mapPanY: 0,
  mapDragging: false,
  mapDragPointerId: null,
  mapDragLastX: 0,
  mapDragLastY: 0,
  mapRotationDeg: 0,
  mapExpanded: false,
};

const wsProtocolName = "piwibus.realtime";
const adminAssetVersion = "20260625-live-timeout-v1";
const adminDisplayVersion = "v7";
const osmTileSize = 256;
const osmProxyTileHost = "/admin/map-tiles";
const osmDirectTileHost = "https://tile.openstreetmap.org";
const osmMinZoom = 8;
const osmMaxZoom = 16;
const mapMinZoomDelta = -3;
const mapMaxZoomDelta = 4;
const liveTripStaleWarningSeconds = 150;

window.PIWIBUS_ADMIN_VERSION = adminAssetVersion;
document.documentElement.dataset.piwibusAdminVersion = adminAssetVersion;
window.showUsers = window.showUsers ?? true;
console.log(
  `Piwibus Admin ${adminAssetVersion} - map tiles: ${osmProxyTileHost} fallback: ${osmDirectTileHost}`,
);

const $ = (id) => document.getElementById(id);

const loginView = $("loginView");
const dashboardView = $("dashboardView");
const connectionState = $("connectionState");

function text(value, fallback = "") {
  if (value === null || value === undefined || value === "") return fallback;
  return String(value);
}

function number(value, digits = 0) {
  const parsed = Number(value || 0);
  if (!Number.isFinite(parsed)) return "0";
  return parsed.toLocaleString("fr-FR", {
    maximumFractionDigits: digits,
    minimumFractionDigits: digits,
  });
}

function dateTime(value) {
  const date = new Date(value || "");
  if (Number.isNaN(date.getTime())) return "-";
  return date.toLocaleString("fr-FR", {
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function durationLabel(startValue, endValue) {
  const start = new Date(startValue || "");
  const end = new Date(endValue || "");
  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) return "-";
  const seconds = Math.max(0, Math.round((end.getTime() - start.getTime()) / 1000));
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = seconds % 60;
  if (minutes >= 60) {
    const hours = Math.floor(minutes / 60);
    const remainingMinutes = minutes % 60;
    return remainingMinutes ? `${hours} h ${remainingMinutes} min` : `${hours} h`;
  }
  if (minutes >= 1) return remainingSeconds ? `${minutes} min ${remainingSeconds} s` : `${minutes} min`;
  return `${seconds} s`;
}

function distanceKm(value) {
  return `${number(value, 1)} km`;
}

function dataSize(bytes) {
  const value = Number(bytes || 0);
  if (!Number.isFinite(value) || value <= 0) return "0 Ko";
  const kib = 1024;
  const mib = kib * 1024;
  if (value >= mib) return `${number(value / mib, 1)} Mo`;
  return `${number(Math.ceil(value / kib))} Ko`;
}

function tripLikeCount(trip) {
  return Math.max(0, Number(trip?.likeCount || trip?.like_count || 0));
}

function tripMessageCount(trip) {
  return Math.max(
    0,
    Number(
      trip?.messageCount ||
        trip?.message_count ||
        (Array.isArray(trip?.messages) ? trip.messages.length : 0),
    ),
  );
}

function tripSocialSummary(trip) {
  const fragment = document.createDocumentFragment();
  appendChildren(
    fragment,
    createElement("span", {
      className: "social-pill",
      textContent: `Likes ${number(tripLikeCount(trip))}`,
    }),
    createElement("span", {
      className: "social-pill",
      textContent: `Chat ${number(tripMessageCount(trip))}`,
    }),
  );
  return fragment;
}

function percent(value, digits = 0) {
  const parsed = Number(value || 0);
  if (!Number.isFinite(parsed)) return "0 %";
  return `${number(parsed * 100, digits)} %`;
}

function clamp(value, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return min;
  return Math.min(max, Math.max(min, parsed));
}

function escapeHtml(value) {
  return text(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

// Audited sink for dynamic HTML. All interpolated values MUST already be
// HTML-escaped (escapeHtml) before being embedded in `html`; this function
// does not sanitize its input.
function renderHtml(element, html) {
  const parsed = new DOMParser().parseFromString(html, "text/html");
  element.replaceChildren(...parsed.body.childNodes);
}
function createElement(tag, options = {}) {
  const element = document.createElement(tag);
  if (options.className) {
    element.className = options.className;
  }
  if (options.textContent !== undefined) {
    element.textContent = text(options.textContent, "");
  }
  if (options.attributes) {
    for (const [name, value] of Object.entries(options.attributes)) {
      if (value === undefined || value === null || value === false) continue;
      if (value === true) {
        element.setAttribute(name, "");
      } else {
        element.setAttribute(name, value);
      }
    }
  }
  if (options.dataset) {
    for (const [name, value] of Object.entries(options.dataset)) {
      if (value === undefined || value === null) continue;
      element.dataset[name] = value;
    }
  }
  if (options.style) {
    Object.assign(element.style, options.style);
  }
  return element;
}

function appendChildren(parent, ...children) {
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    parent.appendChild(child);
  }
  return parent;
}

function createMetricRow(label, value) {
  const row = createElement("div", { className: "metric-row" });
  appendChildren(
    row,
    createElement("span", { textContent: text(label, "") }),
    createElement("strong", { textContent: text(value, "") }),
  );
  return row;
}

function createLinePill(label, colorValue) {
  const pill = createElement("span", {
    className: "line-pill",
    style: { background: color(colorValue) },
  });
  pill.textContent = text(label, "-");
  return pill;
}

function createStatusPill(label, className = "") {
  const pill = createElement("span", {
    className: className ? `status-pill ${className}` : "status-pill",
    textContent: text(label, "-"),
  });
  return pill;
}

function createButton(label, options = {}) {
  const button = createElement("button", {
    attributes: {
      type: options.type || "button",
      ...(options.attributes || {}),
    },
    className: options.className || "",
    textContent: text(label, ""),
    dataset: options.dataset || {},
  });
  if (options.className) {
    button.className = options.className;
  }
  return button;
}

function createCellWithContent(children, className = "") {
  const cell = createElement("td", { className });
  appendChildren(cell, ...(Array.isArray(children) ? children : [children]));
  return cell;
}

function color(value, fallback = "#d62828") {
  const numeric = Number(value || 0);
  if (!Number.isFinite(numeric) || numeric <= 0) return fallback;
  return `#${(numeric & 0xffffff).toString(16).padStart(6, "0")}`;
}

async function api(path, options = {}) {
  const method = (options.method || "GET").toUpperCase();
  const headers = {
    "Content-Type": "application/json",
    ...(options.headers || {}),
  };
  if (state.csrfToken && method !== "GET" && method !== "HEAD") {
    headers["X-CSRF-Token"] = state.csrfToken;
  }
  const response = await fetch(path, {
    ...options,
    headers,
    credentials: "same-origin",
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || body.error) {
    throw new Error(body.error || `Erreur HTTP ${response.status}`);
  }
  return body;
}

function setOnline(value, label = "") {
  connectionState.classList.toggle("is-online", value);
  connectionState.textContent = value ? label || "temps reel" : label || "hors ligne";
}

function showDashboard() {
  loginView.classList.add("is-hidden");
  dashboardView.classList.remove("is-hidden");
}

function showLogin(message = "") {
  dashboardView.classList.add("is-hidden");
  loginView.classList.remove("is-hidden");
  $("loginError").textContent = message;
  setOnline(false);
}

async function login(event) {
  event.preventDefault();
  $("loginError").textContent = "";
  try {
    const result = await api("/admin/auth/login", {
      method: "POST",
      body: JSON.stringify({
        email: $("emailInput").value.trim(),
        password: $("passwordInput").value,
      }),
    });
    state.csrfToken = result.csrfToken || result.dashboard?.csrfToken || "";
    updateDashboard(result.dashboard);
    showDashboard();
    connectRealtime();
    loadMapCatalog();
  } catch (error) {
    $("loginError").textContent = error.message;
  }
}

async function refreshDashboard() {
  try {
    const dashboard = await api("/admin/dashboard");
    updateDashboard(dashboard);
    showDashboard();
    loadMapCatalog();
  } catch (error) {
    state.csrfToken = "";
    showLogin(error.message);
  }
}

function connectRealtime() {
  if (!state.csrfToken) return;
  if (state.eventSource) state.eventSource.close();
  if (state.socket) state.socket.close();
  state.eventSource = null;
  state.socket = null;

  connectWebSocketRealtime();
}

function connectSseRealtime() {
  if (!state.csrfToken || state.eventSource) return;
  try {
    state.eventSource = new EventSource("/admin/events");
    state.eventSource.addEventListener("open", () => setOnline(true, "SSE actif"));
    state.eventSource.addEventListener("dashboard", (event) => {
      updateDashboard(JSON.parse(event.data));
      setOnline(true, "SSE actif");
    });
    state.eventSource.addEventListener("error", () => {
      setOnline(false, "SSE reconnecte");
    });
  } catch {
    setOnline(false);
  }
}

function connectWebSocketRealtime() {
  const protocol = window.location.protocol === "https:" ? "wss" : "ws";
  let fallbackStarted = false;
  const fallbackToSse = () => {
    if (fallbackStarted) return;
    fallbackStarted = true;
    if (state.socket) {
      state.socket.close();
      state.socket = null;
    }
    connectSseRealtime();
  };

  try {
    state.socket = new WebSocket(
      `${protocol}://${window.location.host}/admin/ws`,
      [wsProtocolName],
    );
    state.socket.addEventListener("open", () => setOnline(true, "WebSocket actif"));
    state.socket.addEventListener("message", (event) => {
      const payload = JSON.parse(event.data);
      if (payload.type === "dashboard") {
        updateDashboard(payload.data);
        setOnline(true, "WebSocket actif");
      }
    });
    state.socket.addEventListener("error", () => {
      setOnline(false, "WebSocket indisponible");
      fallbackToSse();
    });
    state.socket.addEventListener("close", () => {
      setOnline(false, "WebSocket ferme");
      fallbackToSse();
    });
  } catch {
    fallbackToSse();
  }
}

const chartInstances = {};

function renderCharts(dashboard) {
  if (typeof Chart === 'undefined') return;
  const stats = dashboard.stats || {};
  const registrations = stats.registrations || {};
  const trips = stats.trips || {};
  const reports = stats.reports || {};
  const deviceVersions = stats.deviceVersions || {};

  updateBarChart("registrationsChart", "Inscriptions", {
    labels: ["Jour", "Semaine", "Mois"],
    values: [registrations.day, registrations.week, registrations.month],
    color: "#d62828",
  });

  updateBarChart("tripsStartedChart", "Trajets demarres", {
    labels: ["Jour", "Semaine", "Mois"],
    values: [trips.startedDay, trips.startedWeek, trips.startedMonth],
    color: "#0f8b8d",
  });

  updateDoughnutChart("tripsOutcomeChart", "Bilan trajets", {
    labels: ["Termines", "Annules systeme", "Hors trace", "Perte connexion"],
    values: [
      trips.ended || 0,
      trips.cancelledBySystem || 0,
      trips.offRouteStops || 0,
      trips.connectionLossStops || 0,
    ],
    colors: ["#2f9e44", "#d1495b", "#ffc300", "#d62828"],
  });

  const reportStatus = Object.entries(reports.byStatus || {})
    .filter(([, v]) => Number(v) > 0)
    .sort((a, b) => Number(b[1]) - Number(a[1]));

  updateDoughnutChart("reportsChart", "Signalements", {
    labels: reportStatus.map(([k]) => k),
    values: reportStatus.map(([, v]) => v),
    colors: ["#0f8b8d", "#ffc300", "#d1495b", "#d62828", "#2f9e44"],
  });

  const platforms = Object.entries(deviceVersions.byPlatform || {})
    .filter(([, v]) => Number(v) > 0)
    .sort((a, b) => Number(b[1]) - Number(a[1]));

  updateDoughnutChart("platformChart", "Plateformes", {
    labels: platforms.map(([k]) => k),
    values: platforms.map(([, v]) => v),
    colors: ["#d62828", "#ffc300", "#0f8b8d", "#2f9e44", "#d1495b"],
  });
}

function updateBarChart(canvasId, label, { labels, values, color }) {
  if (typeof Chart === 'undefined') return;
  const canvas = $(canvasId);
  if (!canvas) return;
  if (chartInstances[canvasId]) chartInstances[canvasId].destroy();

  const ctx = canvas.getContext("2d");
  chartInstances[canvasId] = new Chart(ctx, {
    type: "bar",
    data: {
      labels,
      datasets: [
        {
          label,
          data: values.map((v) => Number(v || 0)),
          backgroundColor: labels.map((_, i) => {
            const alpha = 1 - i * 0.2;
            return hexAlpha(color, alpha);
          }),
          borderColor: color,
          borderWidth: 1,
          borderRadius: 6,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      scales: {
        y: {
          beginAtZero: true,
          ticks: { precision: 0 },
          grid: { color: "rgba(0,0,0,0.06)" },
        },
        x: {
          grid: { display: false },
        },
      },
    },
  });
}

function updateDoughnutChart(canvasId, label, { labels, values, colors }) {
  if (typeof Chart === 'undefined') return;
  const canvas = $(canvasId);
  if (!canvas) return;
  if (chartInstances[canvasId]) chartInstances[canvasId].destroy();

  const total = values.reduce((s, v) => s + Number(v || 0), 0);
  if (total === 0) return;

  const ctx = canvas.getContext("2d");
  chartInstances[canvasId] = new Chart(ctx, {
    type: "doughnut",
    data: {
      labels,
      datasets: [
        {
          data: values.map((v) => Number(v || 0)),
          backgroundColor: colors.slice(0, labels.length),
          borderWidth: 2,
          borderColor: "var(--surface, #ffffff)",
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: {
          position: "bottom",
          labels: { boxWidth: 12, padding: 12, font: { size: 11 } },
        },
      },
    },
  });
}

function hexAlpha(hex, alpha) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r},${g},${b},${alpha})`;
}

function updateDashboard(dashboard) {
  if (!dashboard) return;
  if (dashboard.csrfToken) state.csrfToken = dashboard.csrfToken;
  state.dashboard = dashboard;
  renderSummary(dashboard);
  renderGps(dashboard);
  renderBackend(dashboard);
  renderAttention(dashboard);
  renderQualityAndDevices(dashboard);
  renderPriorityLines(dashboard);
  renderStats(dashboard);
  renderCharts(dashboard);
  renderTrips(dashboard.liveTrips || []);
  renderTripHistory(dashboard.trips || []);
  renderUsers(dashboard.users || []);
  renderReports(dashboard.reports || []);
  renderCatalog(dashboard);
  renderAdminMap(dashboard);
  renderEvents(dashboard.events || []);
  $("notificationResult").textContent = dashboard.notificationResult
    ? `${dashboard.notificationResult.tokens} appareils cibles`
    : "";
}

function renderSummary(data) {
  const overview = data.overview || {};
  const cards = [
    ["Utilisateurs connectes", overview.connectedUsers, "sessions vues depuis 6 min"],
    ["Trajets live actifs", overview.activeTrips, "diffusions ouvertes"],
    ["Etoiles en diffusion", overview.broadcastingStars, "conducteurs live"],
    ["Observateurs & alertes", overview.publicReports, "alertes publiques"],
    ["Hors trace", overview.offRouteTrips, "trajets a surveiller"],
    ["Arrets systeme", overview.systemStoppedTrips, "annulations automatiques"],
  ];
  const container = $("summaryCards");
  container.replaceChildren(
    ...cards.map(([label, value, hint]) => {
      const card = createElement("article", { className: "summary-card" });
      appendChildren(
        card,
        createElement("span", { textContent: text(label, "") }),
        createElement("strong", { textContent: number(value) }),
        createElement("small", { textContent: text(hint, "") }),
      );
      return card;
    }),
  );
}

function renderGps(data) {
  const gps = data.gpsQuality || {};
  $("gpsUpdatedAt").textContent = dateTime(data.generatedAt);
  $("gpsQuality").replaceChildren(
    ...[
      ["Trajets suivis", number(gps.trackedActiveTrips)],
      ["Precision moyenne", `${number(gps.averageAccuracyMeters, 1)} m`],
      ["Age moyen GPS", `${number(gps.averageLocationAgeSeconds, 0)} s`],
      ["Positions perimees", number(gps.staleLocations)],
      ["Trajets hors trace", number(gps.offRouteTrips?.length || 0)],
    ].map(([label, value]) => metricRow([label, value])),
  );
}

function renderBackend(data) {
  const backend = data.backend || {};
  const metrics = backend.metrics || {};
  $("backendStorage").textContent = text(backend.storage, "stockage inconnu");
  $("backendMetrics").replaceChildren(
    ...[
      ["Base de donnees", backend.databaseBacked ? "active" : "fichier/local"],
      ["Geospatial", backend.geospatialQueries ? "active" : "indisponible"],
      ["Requetes HTTP", number(metrics.requestsTotal)],
      ["Erreurs 4xx / 5xx", `${number(metrics.responses4xx)} / ${number(metrics.responses5xx)}`],
      ["Latence moyenne", `${number(metrics.latencyAverageMs, 1)} ms`],
      ["WebSocket / SSE", `${number(metrics.webSocketConnections)} / ${number(metrics.sseConnections)}`],
    ].map(([label, value]) => metricRow([label, value])),
  );
}

function renderAttention(data) {
  const liveTrips = data.liveTrips || [];
  const reports = data.reports || [];
  const allTrips = data.trips || [];
  const lineStats = data.lineStats || [];
  const stats = data.stats || {};
  const ratings = stats.ratings || {};
  const staleTrips = liveTrips.filter((trip) => {
    const gpsTimestamp = trip.liveLocation?.timestamp || trip.lastUpdatedAt;
    const age = secondsSince(gpsTimestamp);
    return !Number.isFinite(age) || age > liveTripStaleWarningSeconds;
  });
  const weakGpsTrips = liveTrips.filter((trip) => {
    const accuracy = Number(trip.liveLocation?.accuracy || 0);
    return Number.isFinite(accuracy) && accuracy > 80;
  });
  const pendingReports = reports.filter((report) => report.status === "en_attente");
  const lowRatedTripsCount =
    Number(ratings.lowRatedTrips || 0) ||
    allTrips.filter(
      (trip) =>
        Number(trip.ratingCount || 0) > 0 &&
        Number(trip.ratingAverage || 0) < 3.5,
    ).length;
  const busiestLine = [...lineStats].sort((a, b) => {
    const scoreA = Number(a.activeTrips || 0) * 100 + Number(a.reports || 0) * 10 + Number(a.observers || 0);
    const scoreB = Number(b.activeTrips || 0) * 100 + Number(b.reports || 0) * 10 + Number(b.observers || 0);
    return scoreB - scoreA;
  })[0];

  const items = [
    {
      label: "GPS a verifier",
      value: staleTrips.length,
      hint: weakGpsTrips.length
        ? `${weakGpsTrips.length} position(s) peu precises`
        : "positions live fraiches",
      level: staleTrips.length ? "danger" : "ok",
    },
    {
      label: "Alertes en attente",
      value: pendingReports.length,
      hint: pendingReports.length
        ? "moderation requise"
        : `${reports.length} alerte(s) suivie(s)`,
      level: pendingReports.length ? "warn" : "ok",
    },
    {
      label: "Trajets mal notes",
      value: lowRatedTripsCount,
      hint: lowRatedTripsCount ? "qualite a analyser" : "aucun signal faible",
      level: lowRatedTripsCount ? "warn" : "ok",
    },
    {
      label: "Erreurs backend",
      value: Number(stats.networkApprox?.errors5xx || 0),
      hint: `${number(stats.networkApprox?.errors4xx)} erreur(s) 4xx`,
      level: Number(stats.networkApprox?.errors5xx || 0) ? "danger" : "ok",
    },
    {
      label: "Ligne la plus active",
      value: busiestLine?.displayCode || "-",
      hint: busiestLine
        ? `${number(busiestLine.activeTrips)} live / ${number(busiestLine.reports)} alerte(s)`
        : "aucune activite ligne",
      level: Number(busiestLine?.activeTrips || 0) ? "ok" : "neutral",
    },
  ];

  $("attentionList").replaceChildren(
    ...items.map((item) => {
      const entry = createElement("div", { className: `attention-item ${item.level}` });
      appendChildren(
        entry,
        createElement("span", { textContent: text(item.label, "") }),
        createElement("strong", { textContent: text(item.value, "") }),
        createElement("small", { textContent: text(item.hint, "") }),
      );
      return entry;
    }),
  );
}

function secondsSince(value) {
  const date = new Date(value || "");
  if (Number.isNaN(date.getTime())) return Number.POSITIVE_INFINITY;
  return Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
}

function gpsAgeLabel(value) {
  const seconds = secondsSince(value);
  if (!Number.isFinite(seconds)) return "age inconnu";
  if (seconds < 60) return `${number(seconds)} s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${number(minutes)} min`;
  return `${number(Math.floor(minutes / 60))} h`;
}

function renderQualityAndDevices(data) {
  const stats = data.stats || {};
  const trips = stats.trips || {};
  const ratings = stats.ratings || {};
  const network = stats.networkUsage || {};
  const notifications = stats.notifications || {};
  const devices = stats.deviceVersions || {};
  const tripRows = data.trips || [];
  const totalLikes = tripRows.reduce((sum, trip) => sum + tripLikeCount(trip), 0);
  const totalMessages = tripRows.reduce(
    (sum, trip) => sum + tripMessageCount(trip),
    0,
  );
  $("qualityMetrics").replaceChildren(
    ...[
      [
        "Note moyenne",
        ratings.totalRatings ? `${number(ratings.average, 1)} / 5` : "-",
      ],
      [
        "Avis recus",
        `${number(ratings.totalRatings)} sur ${number(ratings.ratedTrips)} trajet(s)`,
      ],
      ["Trajets mal notes", number(ratings.lowRatedTrips)],
      ["Likes trajets", number(totalLikes)],
      ["Messages chat", number(totalMessages)],
      ["Duree moyenne", `${number(trips.averageDurationMinutes, 1)} min`],
      ["Distance diffusee", distanceKm(trips.completedDistanceKm)],
      ["Internet trajets", dataSize(network.tripEstimateBytes)],
      ["Internet live", dataSize(network.activeTripEstimateBytes)],
      ["Moyenne par trajet", dataSize(network.averageTripBytes)],
    ].map(([label, value]) => metricRow([label, value])),
  );

  $("deviceMetrics").replaceChildren(
    ...[
      [
        "Appareils actifs",
        `${number(notifications.activeDevices)} / ${number(
          notifications.registeredDevices,
        )}`,
      ],
      ["Plateformes", topEntries(devices.byPlatform, 3)],
      ["Versions app", topEntries(devices.appVersions, 3)],
      ["ABI Android", topEntries(devices.androidAbi, 3)],
      ["SDK Android", topEntries(devices.androidSdk, 3)],
      ["Modeles", topEntries(devices.models, 3)],
    ].map(([label, value]) => metricRow([label, value])),
  );
}

function renderPriorityLines(data) {
  const lines = [...(data.lineStats || [])]
    .filter(
      (line) =>
        Number(line.activeTrips || 0) > 0 ||
        Number(line.reports || 0) > 0 ||
        Number(line.observers || 0) > 0,
    )
    .sort((a, b) => priorityLineScore(b) - priorityLineScore(a))
    .slice(0, 6);
  const maxScore = Math.max(1, ...lines.map(priorityLineScore));
  const container = $("priorityLines");
  if (!lines.length) {
    container.replaceChildren(createElement("p", { textContent: "Aucune ligne prioritaire pour le moment." }));
    return;
  }
  container.replaceChildren(
    ...lines.map((line) => {
      const score = priorityLineScore(line);
      const width = Math.max(8, Math.min(100, Math.round((score / maxScore) * 100)));
      const entry = createElement("div", { className: "priority-line" });
      const main = createElement("div", { className: "priority-line-main" });
      appendChildren(main, linePill(line.displayCode, line.colorValue));
      const content = createElement("div");
      appendChildren(
        content,
        createElement("strong", { textContent: text(line.title || `Ligne ${line.displayCode || "-"}`, "") }),
        createElement("span", {
          textContent: `${number(line.activeTrips)} live - ${number(line.reports)} alerte(s) - ${number(line.observers)} observateur(s)`,
        }),
      );
      appendChildren(main, content);
      const side = createElement("div", { className: "priority-line-side" });
      appendChildren(
        side,
        createElement("strong", { textContent: distanceKm(line.distanceKm) }),
        createElement("div", { className: "priority-meter" }),
      );
      side.querySelector(".priority-meter").appendChild(createElement("span", { style: { width: `${width}%` } }));
      appendChildren(entry, main, side);
      return entry;
    }),
  );
}

function priorityLineScore(line) {
  return (
    Number(line.activeTrips || 0) * 100 +
    Number(line.reports || 0) * 20 +
    Number(line.observers || 0) * 8 +
    Math.min(50, Number(line.distanceKm || 0))
  );
}

function renderStats(data) {
  const stats = data.stats || {};
  const blocks = [
    ["Utilisateurs actifs", `J ${number(stats.activeUsers?.day)} / S ${number(stats.activeUsers?.week)} / M ${number(stats.activeUsers?.month)}`],
    ["Inscriptions", `J ${number(stats.registrations?.day)} / S ${number(stats.registrations?.week)} / M ${number(stats.registrations?.month)}`],
    ["Ouvertures app approx.", `J ${number(stats.appOpeningsApprox?.day)} / S ${number(stats.appOpeningsApprox?.week)} / M ${number(stats.appOpeningsApprox?.month)}`],
    ["Trajets lances", `J ${number(stats.trips?.startedDay)} / S ${number(stats.trips?.startedWeek)} / M ${number(stats.trips?.startedMonth)}`],
    ["Trajets termines", number(stats.trips?.ended)],
    ["Annules systeme", number(stats.trips?.cancelledBySystem)],
    ["Hors trace / connexion", `${number(stats.trips?.offRouteStops)} / ${number(stats.trips?.connectionLossStops)}`],
    ["Duree moyenne", `${number(stats.trips?.averageDurationMinutes, 1)} min`],
    ["Distance diffusee", distanceKm(stats.trips?.completedDistanceKm)],
    ["Distance moyenne", distanceKm(stats.trips?.averageDistanceKm)],
    ["Signalements", `${number(stats.reports?.total)} total`],
    ["Notifications", `${number(stats.notifications?.activeDevices)} appareils actifs`],
    ["Reseau backend", `${number(stats.networkApprox?.backendRequests)} req.`],
    ["ABI Android", topCount(stats.deviceVersions?.androidAbi)],
    ["Versions app", topCount(stats.deviceVersions?.appVersions)],
  ];
  const container = $("detailedStats");
  container.replaceChildren(
    ...blocks.map(([label, value]) => {
      const block = createElement("div", { className: "stat-block" });
      appendChildren(
        block,
        createElement("span", { textContent: text(label, "") }),
        createElement("strong", { textContent: text(value, "") }),
      );
      return block;
    }),
  );
}

function topCount(values) {
  const entries = Object.entries(values || {})
    .filter(([key]) => key && key !== "inconnu")
    .sort((a, b) => Number(b[1]) - Number(a[1]));
  if (!entries.length) return "inconnu";
  return entries
    .slice(0, 2)
    .map(([key, value]) => `${key} (${number(value)})`)
    .join(" / ");
}

function topEntries(values, limit = 2) {
  const entries = Object.entries(values || {})
    .filter(([key]) => key && key !== "inconnu")
    .sort((a, b) => Number(b[1]) - Number(a[1]))
    .slice(0, limit);
  if (!entries.length) return "inconnu";
  return entries.map(([key, value]) => `${key} (${number(value)})`).join(" / ");
}

function renderTrips(trips) {
  $("liveTripCount").textContent = `${trips.length} actif(s)`;
  const table = $("liveTripsTable");
  const rows = [];
  for (const trip of trips) {
    const expanded = state.expandedTrips.has(trip.id);
    const gps = trip.liveLocation || {};
    const statusClass = trip.offRouteSince ? "danger" : "";
    const hasGps = Number.isFinite(Number(gps.lat)) && Number.isFinite(Number(gps.lng));
    const gpsLabel = hasGps ? `${number(gps.lat, 5)} / ${number(gps.lng, 5)}` : "indisponible";
    const gpsAge = gpsAgeLabel(gps.timestamp || trip.lastUpdatedAt);
    const row = createElement("tr");
    appendChildren(
      row,
      createCellWithContent(
        [linePill(trip.displayCode, trip.colorValue), createElement("br"), createElement("small", { textContent: text(trip.lineTitle, "") })],
        "",
      ),
      createCellWithContent(
        [createElement("strong", { textContent: text(trip.ownerName, "") }), createElement("br"), createElement("small", { textContent: dateTime(trip.lastUpdatedAt) })],
        "",
      ),
      createElement("td", { textContent: number(trip.observers) }),
      createElement("td", { textContent: `${number(trip.speedKmh, 1)} km/h` }),
      createCellWithContent(
        [createElement("strong", { textContent: distanceKm(trip.distanceKm) }), createElement("br"), createElement("small", { textContent: `${number((trip.progress || 0) * 100)}%` })],
        "",
      ),
      createCellWithContent(
        [createElement("strong", { textContent: text(gpsLabel, "") }), createElement("br"), createElement("small", { textContent: `${text(gps.accuracy, "-")} m - ${gpsAge}` })],
        "",
      ),
      createCellWithContent(
        [createElement("strong", { textContent: `${number(trip.ratingAverage, 1)} / 5` }), createElement("br"), createElement("small", { textContent: dataSize(trip.networkUsageBytes) })],
        "",
      ),
      createCellWithContent([tripSocialSummary(trip)]),
      createCellWithContent([
        createElement("span", { className: `status-pill ${statusClass}`.trim(), textContent: trip.offRouteSince ? "hors trace" : "actif" }),
        createElement("br"),
        createElement("small", { textContent: text(trip.lastSystemMessage, "") }),
      ], ""),
      createElement("td", { className: "row-actions" }),
    );
    const actionsCell = row.lastElementChild;
    appendChildren(
      actionsCell,
      createElement("button", {
        className: "ghost-button",
        attributes: {
          type: "button",
          "data-trip-details": trip.id,
          "aria-expanded": expanded,
        },
        textContent: expanded ? "Masquer" : "Details",
      }),
      createElement("button", {
        className: "danger-button",
        attributes: {
          type: "button",
          "data-stop-trip": trip.id,
        },
        textContent: "Arreter",
      }),
    );
    rows.push(row);
    if (expanded) rows.push(tripDetailRow(trip, 10));
  }
  table.replaceChildren(...(rows.length ? rows : [emptyRow(10, "Aucun trajet live actif.")]));
}

function renderTripHistory(trips) {
  const completed = trips
    .filter((trip) => trip.status !== "actif")
    .sort((a, b) => new Date(b.lastUpdatedAt || 0) - new Date(a.lastUpdatedAt || 0));
  $("tripHistoryCount").textContent = `${completed.length} trajet(s)`;
  const table = $("tripHistoryTable");
  const rows = [];
  for (const trip of completed) {
    const expanded = state.expandedTrips.has(trip.id);
    const row = createElement("tr");
    appendChildren(
      row,
      createCellWithContent(
        [linePill(trip.displayCode, trip.colorValue), createElement("br"), createElement("small", { textContent: text(trip.lineTitle, "") })],
        "",
      ),
      createCellWithContent(
        [createElement("strong", { textContent: text(trip.ownerName, "") }), createElement("br"), createElement("small", { textContent: text(trip.ownerRole, "") })],
        "",
      ),
      createCellWithContent(
        [createElement("strong", { textContent: dateTime(trip.startedAt) }), createElement("br"), createElement("small", { textContent: dateTime(trip.lastUpdatedAt) })],
        "",
      ),
      createElement("td", { textContent: durationLabel(trip.startedAt, trip.lastUpdatedAt) }),
      createCellWithContent(
        [createElement("strong", { textContent: distanceKm(trip.distanceKm) }), createElement("br"), createElement("small", { textContent: `${number((trip.progress || 0) * 100)}%` })],
        "",
      ),
      createCellWithContent(
        [createElement("strong", { textContent: `max ${number(trip.maxObservers)}` }), createElement("br"), createElement("small", { textContent: `${number(trip.observers)} actuel(s)` })],
        "",
      ),
      createElement("td", { textContent: dataSize(trip.networkUsageBytes) }),
      createCellWithContent(
        [createElement("strong", { textContent: `${number(trip.ratingAverage, 1)} / 5` }), createElement("br"), createElement("small", { textContent: `${number(trip.ratingCount)} avis` })],
        "",
      ),
      createCellWithContent([tripSocialSummary(trip)]),
      createCellWithContent([
        createElement("span", { className: `status-pill ${trip.offRouteSince ? "danger" : ""}`.trim(), textContent: text(trip.status, "") }),
        createElement("br"),
        createElement("small", { textContent: text(trip.lastSystemMessage, "") }),
      ], ""),
      createElement("td", { className: "row-actions" }),
    );
    const actionsCell = row.lastElementChild;
    appendChildren(
      actionsCell,
      createElement("button", {
        className: "ghost-button",
        attributes: {
          type: "button",
          "data-trip-details": trip.id,
          "aria-expanded": expanded,
        },
        textContent: expanded ? "Masquer" : "Details",
      }),
    );
    rows.push(row);
    if (expanded) rows.push(tripDetailRow(trip, 11));
  }
  table.replaceChildren(...(rows.length ? rows : [emptyRow(11, "Aucune diffusion terminee.")]));
}

function renderUsers(users) {
  const query = $("userSearch").value.trim().toLowerCase();
  const visible = users.filter((user) => {
    if (!query) return true;
    return [user.fullName, user.email, user.primaryRole, user.status]
      .join(" ")
      .toLowerCase()
      .includes(query);
  });
  const table = $("usersTable");
  const rows = visible.map((user) => {
    const row = createElement("tr");
    appendChildren(
      row,
      createCellWithContent([
        createElement("strong", { textContent: text(user.fullName, "") }),
        user.connected ? createElement("span", { className: "status-pill", textContent: "connecte" }) : null,
      ]),
      createCellWithContent([
        createElement("strong", { textContent: text(user.email, "") }),
        createElement("br"),
        createElement("small", { textContent: text(user.phone, "") }),
      ]),
      createCellWithContent([
        document.createTextNode(text(user.primaryRole, "")),
        ...(user.isSuperAdmin
          ? [
              createElement("span", {
                className: "status-pill",
                attributes: {
                  style: "background-color: #6C5CE7; color: #FFFFFF; margin-left: 6px;",
                },
                textContent: "Super Admin",
              }),
            ]
          : []),
      ], ""),
      createCellWithContent([
        createElement("span", { className: `status-pill ${user.status === "suspendu" ? "danger" : ""}`.trim(), textContent: text(user.status, "") }),
      ], ""),
      createCellWithContent([
        createElement("strong", { textContent: dateTime(user.lastSeenAt) }),
        createElement("br"),
        createElement("small", { textContent: `${number(user.sessionCount)} session(s)` }),
      ], ""),
      createElement("td", { className: "row-actions" }),
    );
    const actionsCell = row.lastElementChild;
    const currentAdminId = text(state.dashboard?.currentAdmin?.id, "");
    const isSelf = Boolean(currentAdminId && currentAdminId === user.id);
    const isProtected = Boolean(user.isSuperAdmin && user.status !== "suspendu");
    const isSelfActive = Boolean(isSelf && user.status !== "suspendu");
    const buttonAttributes = {
      type: "button",
      "data-toggle-user": user.id,
    };
    if (isSelfActive) {
      buttonAttributes.disabled = "true";
      buttonAttributes.title = "Auto-suspension impossible sur votre propre compte";
    } else if (isProtected) {
      buttonAttributes.disabled = "true";
      buttonAttributes.title = "Ce super utilisateur ne peut pas être suspendu";
    }
    appendChildren(
      actionsCell,
      createElement("button", {
        attributes: buttonAttributes,
        textContent: isSelfActive
          ? "Votre compte"
          : isProtected
          ? "Protégé"
          : user.status === "suspendu"
          ? "Reactiver"
          : "Suspendre",
      }),
    );
    return row;
  });
  table.replaceChildren(...(rows.length ? rows : [emptyRow(6, "Aucun utilisateur.")]));
}

function renderReports(reports) {
  $("reportCount").textContent = `${reports.length} alerte(s)`;
  const table = $("reportsTable");
  const rows = reports.map((report) => {
    const row = createElement("tr");
    appendChildren(
      row,
      createCellWithContent([
        createElement("strong", { textContent: text(report.lineCode, "") }),
        createElement("br"),
        createElement("small", { textContent: text(report.lineLabel, "") }),
      ], ""),
      createElement("td", { textContent: text(report.busNumber, "") }),
      createCellWithContent([
        createElement("strong", { textContent: text(report.reporterName, "") }),
        createElement("br"),
        createElement("small", { textContent: dateTime(report.createdAt) }),
      ], ""),
      createCellWithContent([
        createElement("span", { className: `status-pill ${report.status === "refuse" ? "danger" : report.status === "en_attente" ? "warn" : ""}`.trim(), textContent: text(report.status, "") }),
      ], ""),
      createElement("td", { textContent: percent(report.confidence, 0) }),
      createElement("td", { textContent: text(report.note, "") }),
      createElement("td", { className: "row-actions" }),
    );
    const actionsCell = row.lastElementChild;
    appendChildren(
      actionsCell,
      createElement("button", {
        attributes: {
          type: "button",
          "data-report-status": report.id,
          "data-status": "valide",
        },
        textContent: "Valider",
      }),
      createElement("button", {
        className: "danger-button",
        attributes: {
          type: "button",
          "data-report-status": report.id,
          "data-status": "refuse",
        },
        textContent: "Refuser",
      }),
    );
    return row;
  });
  table.replaceChildren(...(rows.length ? rows : [emptyRow(7, "Aucune alerte.")]));
}

function renderCatalog(data) {
  const layers = data.catalog?.layers || [];
  const layersList = $("layersList");
  layersList.replaceChildren(
    ...layers.map((layer) => {
      const item = createElement("div", { className: "layer-item" });
      const content = createElement("div");
      appendChildren(
        content,
        createElement("strong", { textContent: text(layer.name, "") }),
        createElement("br"),
        createElement("span", { textContent: text(layer.scope, "") }),
      );
      appendChildren(item, content, createElement("span", { textContent: text(layer.source, "") }));
      return item;
    }),
  );

  const query = $("lineSearch").value.trim().toLowerCase();
  const lines = (data.lineStats || []).filter((line) => {
    if (!query) return true;
    return [line.displayCode, line.title].join(" ").toLowerCase().includes(query);
  });
  const table = $("linesTable");
  const rows = lines.map((line) => {
    const row = createElement("tr");
    appendChildren(
      row,
      createElement("td", { className: "" }),
      createElement("td", { textContent: text(line.title, "") }),
      createElement("td", { textContent: `${number(line.trips)} dont ${number(line.activeTrips)} actif(s)` }),
      createElement("td", { textContent: distanceKm(line.distanceKm) }),
      createElement("td", { textContent: number(line.reports) }),
      createElement("td", { textContent: number(line.observers) }),
    );
    row.firstElementChild.appendChild(linePill(line.displayCode, line.colorValue));
    return row;
  });
  table.replaceChildren(...(rows.length ? rows : [emptyRow(6, "Aucune ligne.")]));
}

async function loadMapCatalog({ force = false } = {}) {
  if (!state.csrfToken || state.mapCatalogLoading) return;
  if (state.mapCatalog && !force) return;
  state.mapCatalogLoading = true;
  setMapStatus("chargement des traces");
  try {
    state.mapCatalog = await api("/admin/map-data");
    populateMapLineFilter();
    renderAdminMap(state.dashboard || {});
  } catch (error) {
    setMapStatus(error.message || "carte indisponible");
  } finally {
    state.mapCatalogLoading = false;
  }
}

function populateMapLineFilter() {
  const select = $("mapLineFilter");
  if (!select) return;
  const previous = state.mapSelectedLine || select.value || "";
  const lines = [...(state.mapCatalog?.lines || [])].sort((a, b) =>
    text(a.displayCode).localeCompare(text(b.displayCode), "fr", {
      numeric: true,
      sensitivity: "base",
    }),
  );
  select.replaceChildren(
    createElement("option", { attributes: { value: "" }, textContent: "Toutes les lignes" }),
    ...lines.map((line) => {
      const option = createElement("option", {
        attributes: { value: text(line.lineCode, "") },
        textContent: `${text(line.displayCode, "")} - ${text(line.title || "Itineraire", "")}`,
      });
      return option;
    }),
  );
  if (previous && lines.some((line) => line.lineCode === previous)) {
    select.value = previous;
    state.mapSelectedLine = previous;
  }
}

function renderAdminMap(dashboard = {}) {
  const canvas = $("adminMapCanvas");
  if (!canvas) return;
  updateMapControlState();
  const catalogLines = state.mapCatalog?.lines || [];
  const liveTrips = dashboard.liveTrips || [];
  const liveUsers = dashboard.liveUsers || [];
  const selectedLine = state.mapSelectedLine || $("mapLineFilter")?.value || "";
  const selectedLineData = catalogLines.find((line) => line.lineCode === selectedLine) || null;
  const liveOnly = $("mapLiveOnly")?.checked || false;
  const showUsers = $("mapShowUsers")?.checked ?? true;
  const activeLineCodes = new Set(liveTrips.map((trip) => text(trip.lineCode)));
  const visibleUsers = showUsers
    ? filterUsersByLineProximity(liveUsers, selectedLineData, state.mapUserRadiusMeters)
    : [];
  const visibleLines = catalogLines.filter((line) => {
    if (selectedLine && line.lineCode !== selectedLine) return false;
    if (liveOnly && !activeLineCodes.has(line.lineCode)) return false;
    return true;
  });
  const visibleTrips = liveTrips.filter((trip) => {
    if (selectedLine && trip.lineCode !== selectedLine) return false;
    return true;
  });

  renderMapSidePanel(visibleTrips, visibleLines, visibleUsers, showUsers);
  const tileStats = drawAdminMap(canvas, visibleLines, visibleTrips, visibleUsers, showUsers);
  updateMapControlState();

  if (!state.mapCatalog) {
    setMapStatus(state.mapCatalogLoading ? "chargement des traces" : "traces non chargees");
  } else {
    const tileLabel = mapTileStatusLabel(tileStats);
    const mapBaseLabel = state.mapTilesVisible ? "OpenStreetMap" : "fond masque";
    setMapStatus(
      `Carte ${adminDisplayVersion} - ${number(visibleLines.length)} ligne(s) - ${number(visibleTrips.length)} live - ${mapBaseLabel}${tileLabel}`,
    );
  }
}

function mapTileStatusLabel(tileStats) {
  if (!tileStats || tileStats.total <= 0) return "";
  if (tileStats.hidden) return "";
  const parts = [];
  if (tileStats.loaded < tileStats.total || tileStats.failed > 0) {
    parts.push(`tuiles ${number(tileStats.loaded)}/${number(tileStats.total)}`);
  }
  if (tileStats.fallback > 0) {
    parts.push(`secours direct ${number(tileStats.fallback)}`);
  }
  if (tileStats.failed > 0) {
    parts.push(`${number(tileStats.failed)} echec(s)`);
  }
  return parts.length ? ` - ${parts.join(" - ")}` : "";
}

function renderMapSidePanel(liveTrips, visibleLines, liveUsers, showUsers = true) {
  const showUsersValue = typeof showUsers === "boolean" ? showUsers : window.showUsers;
  $("mapLiveCount").textContent = `${number(liveTrips.length)} actif(s)`;
  $("mapUserCount").textContent = `${number(liveUsers.length)}${showUsersValue ? "" : " (masque)"}`;
  $("mapLineCount").textContent = `${number(visibleLines.length)} ligne(s)`;

  const liveList = $("mapLiveList");
  liveList.replaceChildren(
    ...(liveTrips.length
      ? liveTrips.map((trip) => {
          const gps = trip.liveLocation || {};
          const gpsAge = gpsAgeLabel(gps.timestamp || trip.lastUpdatedAt);
          const status = trip.offRouteSince ? "hors trace" : gpsAge;
          const button = createElement("button", {
            className: "map-live-item",
            attributes: {
              type: "button",
              "data-map-line": trip.lineCode,
            },
          });
          appendChildren(
            button,
            createElement("span", { className: "" }),
            createElement("strong", { textContent: text(trip.ownerName || "Trajet live", "") }),
            createElement("small", { textContent: `${number(trip.speedKmh, 1)} km/h - ${number(trip.observers)} observateur(s) - ${text(status, "")}` }),
          );
          button.firstElementChild.appendChild(linePill(trip.displayCode, trip.colorValue));
          return button;
        })
      : [createElement("p", { className: "muted-text", textContent: "Aucun trajet diffuse actuellement." })]),
  );

  const userList = $("mapUserList");
  userList.replaceChildren(
    ...(showUsersValue && liveUsers.length
      ? liveUsers.map((user) => {
          const location = user.location || {};
          const age = gpsAgeLabel(location.timestamp);
          const item = createElement("div", { className: "map-live-item" });
          const first = createElement("span");
          first.appendChild(linePill(user.displayCode || "U", "#0f8b8d"));
          appendChildren(
            item,
            first,
            createElement("strong", { textContent: text(user.fullName || user.name || user.email || "Utilisateur", "") }),
            createElement("small", { textContent: `${text(age, "")}${location.lat != null && location.lng != null ? " - GPS" : ""}` }),
          );
          return item;
        })
      : [createElement("p", { className: "muted-text", textContent: "Aucun utilisateur visible pour le moment." })]),
  );

  const legend = $("mapLegend");
  legend.replaceChildren(
    ...(visibleLines.slice(0, 18).length
      ? visibleLines.slice(0, 18).map((line) => {
          const button = createElement("button", {
            className: "map-legend-item",
            attributes: {
              type: "button",
              "data-map-line": line.lineCode,
            },
          });
          const swatch = createElement("span", { style: { background: color(line.colorValue) } });
          appendChildren(
            button,
            swatch,
            createElement("strong", { textContent: text(line.displayCode, "") }),
            createElement("small", { textContent: text(line.title || "Itineraire", "") }),
          );
          return button;
        })
      : [createElement("p", { className: "muted-text", textContent: "Aucune ligne visible." })]),
  );
}

function drawAdminMap(canvas, lines, liveTrips, liveUsers, showUsers = true) {
  const showUsersValue = typeof showUsers === "boolean" ? showUsers : window.showUsers;
  const rect = canvas.getBoundingClientRect();
  const width = Math.max(320, Math.round(rect.width || canvas.clientWidth || 960));
  const height = Math.max(360, Math.round(rect.height || canvas.clientHeight || 620));
  const ratio = window.devicePixelRatio || 1;
  if (canvas.width !== Math.round(width * ratio)) canvas.width = Math.round(width * ratio);
  if (canvas.height !== Math.round(height * ratio)) canvas.height = Math.round(height * ratio);
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);

  const bounds = mapBounds(lines, liveTrips, liveUsers);
  state.mapMarkers = [];

  const mapView = createMapView(bounds, width, height, 34);
  const project = mapView.project;
  const tileStats = state.mapTilesVisible
    ? drawOsmTiles(ctx, mapView, width, height)
    : drawHiddenMapBase(ctx, mapView, width, height);
  drawMapLabels(ctx, width, height);

  if (!state.mapCatalog) {
    drawMapEmpty(ctx, width, height, "Chargement des traces de lignes...");
    return tileStats;
  }

  for (const line of lines) {
    const active = liveTrips.some((trip) => trip.lineCode === line.lineCode);
    drawLineSegments(ctx, project, line, {
      active,
      selected: state.mapSelectedLine === line.lineCode,
    });
  }

  drawLiveTrips(ctx, project, liveTrips);
  if (showUsersValue) drawLiveUsers(ctx, project, liveUsers);
  drawIvoryCoastInset(ctx, width, height);

  if (!lines.length && !liveTrips.length) {
    drawMapEmpty(ctx, width, height, "Aucune ligne a afficher avec ce filtre.");
  }
  return tileStats;
}

function setMapStatus(label) {
  const status = $("mapStatus");
  if (status) status.textContent = label;
}

function mapBounds(lines, liveTrips, liveUsers = []) {
  const points = [];
  for (const line of lines) {
    for (const segment of line.segments || []) {
      for (const point of segment) {
        if (isValidLatLng(point)) points.push(point);
      }
    }
  }
  if ($("mapFollowLive")?.checked) {
    for (const trip of liveTrips) {
      const point = tripPoint(trip);
      if (point) points.push(point);
    }
  }
  const showUsersValue = window.showUsers ?? true;
  if (showUsersValue && liveUsers.length) {
    for (const user of liveUsers) {
      const point = userPoint(user);
      if (point) points.push(point);
    }
  }
  if (!points.length && state.mapCatalog?.bounds) {
    const bounds = state.mapCatalog.bounds;
    points.push(
      { lat: bounds.minLat, lng: bounds.minLng },
      { lat: bounds.maxLat, lng: bounds.maxLng },
    );
  }
  if (!points.length) {
    points.push({ lat: 5.15, lng: -4.22 }, { lat: 5.52, lng: -3.75 });
  }
  const minLat = Math.min(...points.map((point) => Number(point.lat)));
  const maxLat = Math.max(...points.map((point) => Number(point.lat)));
  const minLng = Math.min(...points.map((point) => Number(point.lng)));
  const maxLng = Math.max(...points.map((point) => Number(point.lng)));
  const latPad = Math.max(0.012, (maxLat - minLat) * 0.12);
  const lngPad = Math.max(0.012, (maxLng - minLng) * 0.12);
  return {
    minLat: minLat - latPad,
    maxLat: maxLat + latPad,
    minLng: minLng - lngPad,
    maxLng: maxLng + lngPad,
  };
}

function createMapView(bounds, width, height, padding) {
  const minWorld = latLngToWorld(bounds.maxLat, bounds.minLng, 0);
  const maxWorld = latLngToWorld(bounds.minLat, bounds.maxLng, 0);
  const spanX = Math.max(0.0001, Math.abs(maxWorld.x - minWorld.x));
  const spanY = Math.max(0.0001, Math.abs(maxWorld.y - minWorld.y));
  const availableWidth = Math.max(1, width - padding * 2);
  const availableHeight = Math.max(1, height - padding * 2);
  const rawZoom = Math.floor(
    Math.log2(Math.min(availableWidth / spanX, availableHeight / spanY)),
  );
  const zoom = clamp(rawZoom + state.mapZoomDelta, osmMinZoom, osmMaxZoom);
  state.mapCurrentZoom = zoom;
  const topLeftAtZoom = latLngToWorld(bounds.maxLat, bounds.minLng, zoom);
  const bottomRightAtZoom = latLngToWorld(bounds.minLat, bounds.maxLng, zoom);
  const centerWorld = {
    x: (topLeftAtZoom.x + bottomRightAtZoom.x) / 2,
    y: (topLeftAtZoom.y + bottomRightAtZoom.y) / 2,
  };
  const topLeft = {
    x: centerWorld.x - width / 2 + state.mapPanX,
    y: centerWorld.y - height / 2 + state.mapPanY,
  };
  return {
    zoom,
    topLeft,
    project: (point) => {
      const world = latLngToWorld(point.lat, point.lng, zoom);
      return {
        x: world.x - topLeft.x,
        y: world.y - topLeft.y,
      };
    },
  };
}

function adjustMapZoom(delta) {
  if (delta > 0 && state.mapCurrentZoom >= osmMaxZoom) return;
  if (delta < 0 && state.mapCurrentZoom <= osmMinZoom) return;
  const nextZoomDelta = clamp(
    state.mapZoomDelta + delta,
    mapMinZoomDelta,
    mapMaxZoomDelta,
  );
  if (nextZoomDelta === state.mapZoomDelta) return;
  state.mapZoomDelta = nextZoomDelta;
  renderAdminMap(state.dashboard || {});
}

function resetMapNorth() {
  state.mapRotationDeg = 0;
  renderAdminMap(state.dashboard || {});
}

function recenterMap() {
  state.mapZoomDelta = 0;
  state.mapPanX = 0;
  state.mapPanY = 0;
  renderAdminMap(state.dashboard || {});
}

function toggleMapTiles() {
  state.mapTilesVisible = !state.mapTilesVisible;
  renderAdminMap(state.dashboard || {});
}

function startMapDrag(event) {
  if (event.pointerType === "mouse" && event.button !== 0) return;
  const canvas = $("adminMapCanvas");
  if (!canvas) return;
  state.mapDragging = true;
  state.mapDragPointerId = event.pointerId;
  state.mapDragLastX = event.clientX;
  state.mapDragLastY = event.clientY;
  canvas.classList.add("is-dragging");
  canvas.setPointerCapture?.(event.pointerId);
  $("mapTooltip")?.classList.add("is-hidden");
  event.preventDefault();
}

function moveMapDrag(event) {
  if (!state.mapDragging || state.mapDragPointerId !== event.pointerId) return;
  const deltaX = event.clientX - state.mapDragLastX;
  const deltaY = event.clientY - state.mapDragLastY;
  if (deltaX === 0 && deltaY === 0) return;
  state.mapDragLastX = event.clientX;
  state.mapDragLastY = event.clientY;
  state.mapPanX -= deltaX;
  state.mapPanY -= deltaY;
  $("mapTooltip")?.classList.add("is-hidden");
  renderAdminMap(state.dashboard || {});
  event.preventDefault();
}

function endMapDrag(event) {
  if (!state.mapDragging || state.mapDragPointerId !== event.pointerId) return;
  state.mapDragging = false;
  state.mapDragPointerId = null;
  $("adminMapCanvas")?.classList.remove("is-dragging");
  event.currentTarget?.releasePointerCapture?.(event.pointerId);
}

function panMapBy(deltaX, deltaY) {
  state.mapPanX += deltaX;
  state.mapPanY += deltaY;
  renderAdminMap(state.dashboard || {});
}

async function toggleMapExpanded() {
  const shell = $("adminMapShell");
  if (!shell) return;
  try {
    if (document.fullscreenElement === shell) {
      await document.exitFullscreen();
    } else if (shell.requestFullscreen) {
      await shell.requestFullscreen();
    } else {
      state.mapExpanded = !state.mapExpanded;
      shell.classList.toggle("is-expanded", state.mapExpanded);
      renderAdminMap(state.dashboard || {});
      updateMapControlState();
    }
  } catch {
    state.mapExpanded = !state.mapExpanded;
    shell.classList.toggle("is-expanded", state.mapExpanded);
    renderAdminMap(state.dashboard || {});
    updateMapControlState();
  }
}

function updateMapControlState() {
  const zoomIn = $("mapZoomInButton");
  const zoomOut = $("mapZoomOutButton");
  const north = $("mapNorthButton");
  const tiles = $("mapTilesButton");
  const expand = $("mapExpandButton");
  const shell = $("adminMapShell");
  if (zoomIn) zoomIn.disabled = state.mapCurrentZoom >= osmMaxZoom;
  if (zoomOut) zoomOut.disabled = state.mapCurrentZoom <= osmMinZoom;
  if (north) north.classList.toggle("is-active", state.mapRotationDeg === 0);
  if (tiles) {
    tiles.classList.toggle("is-muted", !state.mapTilesVisible);
    tiles.textContent = state.mapTilesVisible ? "Fond OSM" : "Fond masque";
    tiles.setAttribute("aria-pressed", state.mapTilesVisible ? "true" : "false");
    tiles.setAttribute(
      "aria-label",
      state.mapTilesVisible
        ? "Masquer le fond OpenStreetMap"
        : "Afficher le fond OpenStreetMap",
    );
    tiles.title = state.mapTilesVisible
      ? "Masquer le fond OpenStreetMap"
      : "Afficher le fond OpenStreetMap";
  }
  shell?.classList.toggle("is-tiles-hidden", !state.mapTilesVisible);
  const isFullscreen = document.fullscreenElement === shell || state.mapExpanded;
  if (expand) {
    expand.textContent = isFullscreen ? "Reduire" : "Agrandir";
    expand.setAttribute(
      "aria-label",
      isFullscreen ? "Reduire la carte" : "Agrandir la carte",
    );
    expand.title = isFullscreen ? "Reduire la carte" : "Agrandir la carte";
  }
}

function latLngToWorld(lat, lng, zoom) {
  const scale = osmTileSize * 2 ** zoom;
  const safeLat = clamp(Number(lat), -85.05112878, 85.05112878);
  const safeLng = Number(lng);
  const sin = Math.sin((safeLat * Math.PI) / 180);
  return {
    x: ((safeLng + 180) / 360) * scale,
    y: (0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * scale,
  };
}

function drawOsmTiles(ctx, mapView, width, height) {
  ctx.fillStyle = "#eef0ea";
  ctx.fillRect(0, 0, width, height);
  const zoom = mapView.zoom;
  const tileCount = 2 ** zoom;
  const startX = Math.floor(mapView.topLeft.x / osmTileSize);
  const endX = Math.floor((mapView.topLeft.x + width) / osmTileSize);
  const startY = Math.floor(mapView.topLeft.y / osmTileSize);
  const endY = Math.floor((mapView.topLeft.y + height) / osmTileSize);
  let loaded = 0;
  let total = 0;
  let failed = 0;
  let fallback = 0;

  for (let tileX = startX; tileX <= endX; tileX += 1) {
    for (let tileY = startY; tileY <= endY; tileY += 1) {
      if (tileY < 0 || tileY >= tileCount) continue;
      total += 1;
      const wrappedX = ((tileX % tileCount) + tileCount) % tileCount;
      const tilePath = `${zoom}/${wrappedX}/${tileY}.png`;
      const tile = getOsmTile(
        `${osmProxyTileHost}/${tilePath}`,
        `${osmDirectTileHost}/${tilePath}`,
      );
      const dx = Math.round(tileX * osmTileSize - mapView.topLeft.x);
      const dy = Math.round(tileY * osmTileSize - mapView.topLeft.y);
      if (tile.loaded) {
        loaded += 1;
        if (tile.fallback) fallback += 1;
        ctx.drawImage(tile.image, dx, dy, osmTileSize, osmTileSize);
      } else {
        if (tile.failed) failed += 1;
        drawTilePlaceholder(ctx, dx, dy);
      }
    }
  }
  return { loaded, total, failed, fallback, zoom };
}

function drawHiddenMapBase(ctx, mapView, width, height) {
  ctx.fillStyle = "#f3efe8";
  ctx.fillRect(0, 0, width, height);
  const startX = Math.floor(mapView.topLeft.x / osmTileSize) * osmTileSize - mapView.topLeft.x;
  const startY = Math.floor(mapView.topLeft.y / osmTileSize) * osmTileSize - mapView.topLeft.y;
  ctx.save();
  ctx.strokeStyle = "rgba(34, 34, 34, 0.055)";
  ctx.lineWidth = 1;
  for (let x = startX; x <= width; x += osmTileSize) {
    ctx.beginPath();
    ctx.moveTo(Math.round(x), 0);
    ctx.lineTo(Math.round(x), height);
    ctx.stroke();
  }
  for (let y = startY; y <= height; y += osmTileSize) {
    ctx.beginPath();
    ctx.moveTo(0, Math.round(y));
    ctx.lineTo(width, Math.round(y));
    ctx.stroke();
  }
  ctx.restore();
  return {
    loaded: 0,
    total: 1,
    failed: 0,
    fallback: 0,
    hidden: true,
    zoom: mapView.zoom,
  };
}

function getOsmTile(primaryUrl, fallbackUrl = "") {
  let tile = state.mapTileCache.get(primaryUrl);
  if (tile) return tile;
  const image = new Image();
  image.crossOrigin = "anonymous";
  tile = {
    image,
    loaded: false,
    failed: false,
    fallback: false,
  };
  const redrawMap = () => {
    if (state.dashboard) requestAnimationFrame(() => renderAdminMap(state.dashboard || {}));
  };
  image.onload = () => {
    tile.loaded = true;
    tile.failed = false;
    redrawMap();
  };
  image.onerror = () => {
    if (fallbackUrl && !tile.fallback) {
      tile.fallback = true;
      tile.loaded = false;
      tile.failed = false;
      image.src = fallbackUrl;
      return;
    }
    tile.failed = true;
    redrawMap();
  };
  image.src = primaryUrl;
  state.mapTileCache.set(primaryUrl, tile);
  pruneTileCache();
  return tile;
}

function pruneTileCache() {
  const maxTiles = 640;
  if (state.mapTileCache.size <= maxTiles) return;
  const keys = state.mapTileCache.keys();
  while (state.mapTileCache.size > maxTiles) {
    const next = keys.next();
    if (next.done) break;
    state.mapTileCache.delete(next.value);
  }
}

function drawTilePlaceholder(ctx, x, y) {
  ctx.fillStyle = "#e7e3dc";
  ctx.fillRect(x, y, osmTileSize, osmTileSize);
  ctx.strokeStyle = "rgba(34, 34, 34, 0.045)";
  ctx.strokeRect(x, y, osmTileSize, osmTileSize);
}

function drawMapLabels(ctx, width, height) {
  ctx.save();
  ctx.fillStyle = "rgba(34, 34, 34, 0.62)";
  ctx.font = "800 12px Inter, sans-serif";
  ctx.fillText("Cote d'Ivoire / Abidjan", 24, height - 24);
  ctx.restore();
}

function drawLineSegments(ctx, project, line, { active, selected }) {
  const stroke = color(line.colorValue);
  ctx.save();
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.strokeStyle = stroke;
  ctx.globalAlpha = selected ? 0.95 : active ? 0.82 : 0.36;
  ctx.lineWidth = selected ? 6 : active ? 4.6 : 2.35;

  for (const segment of line.segments || []) {
    if (!Array.isArray(segment) || segment.length < 2) continue;
    ctx.beginPath();
    segment.forEach((point, index) => {
      const screen = project(point);
      if (index === 0) ctx.moveTo(screen.x, screen.y);
      else ctx.lineTo(screen.x, screen.y);
    });
    ctx.stroke();
  }

  if (active || selected) {
    const labelPoint = firstValidPoint(line);
    if (labelPoint) drawLineLabel(ctx, project(labelPoint), line);
  }
  ctx.restore();
}

function drawLineLabel(ctx, screen, line) {
  const label = text(line.displayCode, "-");
  ctx.save();
  ctx.font = "900 11px Inter, sans-serif";
  const width = Math.max(28, ctx.measureText(label).width + 14);
  ctx.fillStyle = color(line.colorValue);
  roundRect(ctx, screen.x + 7, screen.y - 15, width, 22, 11);
  ctx.fill();
  ctx.fillStyle = "#fff";
  ctx.fillText(label, screen.x + 14, screen.y);
  ctx.restore();
}

function drawLiveTrips(ctx, project, liveTrips) {
  for (const trip of liveTrips) {
    const point = tripPoint(trip);
    if (!point) continue;
    const screen = project(point);
    const tripColor = color(trip.colorValue);
    const stale =
      secondsSince(trip.liveLocation?.timestamp || trip.lastUpdatedAt) >
      liveTripStaleWarningSeconds;
    const offRoute = Boolean(trip.offRouteSince);
    state.mapMarkers.push({ ...screen, trip });

    ctx.save();
    ctx.beginPath();
    ctx.arc(screen.x, screen.y, offRoute ? 18 : 15, 0, Math.PI * 2);
    ctx.fillStyle = offRoute ? "rgba(209, 73, 91, 0.18)" : "rgba(47, 158, 68, 0.16)";
    ctx.fill();
    ctx.lineWidth = offRoute ? 4 : stale ? 3 : 2;
    ctx.strokeStyle = offRoute ? "#d1495b" : stale ? "#ffc300" : "#2f9e44";
    ctx.stroke();

    ctx.beginPath();
    ctx.arc(screen.x, screen.y, 10, 0, Math.PI * 2);
    ctx.fillStyle = tripColor;
    ctx.fill();
    ctx.lineWidth = 2;
    ctx.strokeStyle = "#fff";
    ctx.stroke();

    const heading = Number(trip.liveLocation?.heading);
    if (Number.isFinite(heading)) {
      drawHeading(ctx, screen, heading, offRoute ? "#d1495b" : tripColor);
    }

    ctx.fillStyle = "#fff";
    ctx.font = "900 9px Inter, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(text(trip.displayCode, "-").slice(0, 3), screen.x, screen.y + 0.5);
    ctx.restore();
  }
}

function drawLiveUsers(ctx, project, liveUsers) {
  for (const user of liveUsers) {
    const point = userPoint(user);
    if (!point) continue;
    const screen = project(point);
    state.mapMarkers.push({ ...screen, type: "user", user });

    ctx.save();
    ctx.beginPath();
    ctx.arc(screen.x, screen.y, 12, 0, Math.PI * 2);
    ctx.fillStyle = "rgba(15, 139, 141, 0.16)";
    ctx.fill();
    ctx.lineWidth = 2;
    ctx.strokeStyle = "#0f8b8d";
    ctx.stroke();

    ctx.beginPath();
    ctx.arc(screen.x, screen.y, 6, 0, Math.PI * 2);
    ctx.fillStyle = "#0f8b8d";
    ctx.fill();
    ctx.strokeStyle = "#fff";
    ctx.stroke();
    ctx.restore();
  }
}

function drawHeading(ctx, screen, heading, fill) {
  const radians = ((heading - 90) * Math.PI) / 180;
  const tip = {
    x: screen.x + Math.cos(radians) * 22,
    y: screen.y + Math.sin(radians) * 22,
  };
  ctx.save();
  ctx.strokeStyle = fill;
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(screen.x, screen.y);
  ctx.lineTo(tip.x, tip.y);
  ctx.stroke();
  ctx.restore();
}

function drawIvoryCoastInset(ctx, width, height) {
  const inset = { x: width - 180, y: 18, w: 148, h: 112 };
  const outline = [
    [-8.6, 6.6],
    [-8.25, 8.1],
    [-7.45, 9.15],
    [-7.35, 10.35],
    [-6.35, 10.75],
    [-5.25, 10.35],
    [-4.35, 10.65],
    [-3.25, 9.85],
    [-2.65, 8.75],
    [-2.9, 7.2],
    [-3.1, 5.4],
    [-3.55, 4.9],
    [-4.6, 5.12],
    [-5.75, 4.98],
    [-6.8, 4.65],
    [-7.75, 4.42],
    [-8.45, 5.18],
    [-8.6, 6.6],
  ];
  const bounds = { minLng: -8.8, maxLng: -2.45, minLat: 4.2, maxLat: 10.9 };
  const p = ([lng, lat]) => ({
    x: inset.x + ((lng - bounds.minLng) / (bounds.maxLng - bounds.minLng)) * inset.w,
    y: inset.y + ((bounds.maxLat - lat) / (bounds.maxLat - bounds.minLat)) * inset.h,
  });
  ctx.save();
  ctx.fillStyle = "rgba(255, 255, 255, 0.82)";
  ctx.strokeStyle = "rgba(34, 34, 34, 0.1)";
  roundRect(ctx, inset.x - 10, inset.y - 8, inset.w + 20, inset.h + 34, 14);
  ctx.fill();
  ctx.stroke();
  ctx.beginPath();
  outline.forEach((point, index) => {
    const screen = p(point);
    if (index === 0) ctx.moveTo(screen.x, screen.y);
    else ctx.lineTo(screen.x, screen.y);
  });
  ctx.closePath();
  ctx.fillStyle = "rgba(214, 40, 40, 0.08)";
  ctx.strokeStyle = "rgba(214, 40, 40, 0.52)";
  ctx.lineWidth = 1.5;
  ctx.fill();
  ctx.stroke();
  const abidjan = p([-4.03, 5.35]);
  ctx.beginPath();
  ctx.arc(abidjan.x, abidjan.y, 4, 0, Math.PI * 2);
  ctx.fillStyle = "#d62828";
  ctx.fill();
  ctx.fillStyle = "rgba(34, 34, 34, 0.66)";
  ctx.font = "800 10px Inter, sans-serif";
  ctx.fillText("Cote d'Ivoire", inset.x + 6, inset.y + inset.h + 18);
  ctx.restore();
}

function drawMapEmpty(ctx, width, height, label) {
  ctx.save();
  ctx.fillStyle = "rgba(34, 34, 34, 0.52)";
  ctx.font = "900 16px Inter, sans-serif";
  ctx.textAlign = "center";
  ctx.fillText(label, width / 2, height / 2);
  ctx.restore();
}

function tripPoint(trip) {
  const gps = trip.liveLocation || {};
  const point = { lat: Number(gps.lat), lng: Number(gps.lng) };
  return isValidLatLng(point) ? point : null;
}

function userPoint(user) {
  const location = user?.location || {};
  const point = { lat: Number(location.lat), lng: Number(location.lng) };
  return isValidLatLng(point) ? point : null;
}

function filterUsersByLineProximity(liveUsers, selectedLine, radiusMeters) {
  if (!selectedLine || !Number.isFinite(radiusMeters) || radiusMeters <= 0) {
    return liveUsers;
  }
  return liveUsers.filter((user) => {
    const point = userPoint(user);
    if (!point) return false;
    return userDistanceToLineMeters(point, selectedLine) <= radiusMeters;
  });
}

function userDistanceToLineMeters(point, line) {
  if (!line?.segments?.length) return Infinity;
  let bestDistance = Infinity;
  for (const segment of line.segments) {
    if (!Array.isArray(segment) || segment.length < 2) continue;
    for (let index = 0; index < segment.length - 1; index += 1) {
      const a = segment[index];
      const b = segment[index + 1];
      if (!isValidLatLng(a) || !isValidLatLng(b)) continue;
      const distance = distanceMetersToSegment(point, a, b);
      if (distance < bestDistance) bestDistance = distance;
    }
  }
  return bestDistance;
}

function distanceMetersToSegment(point, a, b) {
  const lat1 = Number(a.lat);
  const lng1 = Number(a.lng);
  const lat2 = Number(b.lat);
  const lng2 = Number(b.lng);
  const lat = Number(point.lat);
  const lng = Number(point.lng);
  const earthRadiusMeters = 6371000;
  const toRadians = (value) => (value * Math.PI) / 180;
  const lat1Rad = toRadians(lat1);
  const lng1Rad = toRadians(lng1);
  const lat2Rad = toRadians(lat2);
  const lng2Rad = toRadians(lng2);
  const latRad = toRadians(lat);
  const lngRad = toRadians(lng);
  const dLat = lat2Rad - lat1Rad;
  const dLng = lng2Rad - lng1Rad;
  const aValue =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1Rad) * Math.cos(lat2Rad) * Math.sin(dLng / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(aValue), Math.sqrt(1 - aValue));
  const segmentLength = earthRadiusMeters * c;
  if (segmentLength === 0) {
    return distanceMetersBetweenPoints(point, a);
  }
  const x = ((latRad - lat1Rad) * Math.cos((lat1Rad + lat2Rad) / 2)) / 1;
  const y = lngRad - lng1Rad;
  const projection = ((x * (lat2Rad - lat1Rad) + y * (lng2Rad - lng1Rad)) / (dLat * dLat + dLng * dLng));
  const clamped = clamp(projection, 0, 1);
  const projectedLat = lat1 + (lat2 - lat1) * clamped;
  const projectedLng = lng1 + (lng2 - lng1) * clamped;
  return distanceMetersBetweenPoints(point, { lat: projectedLat, lng: projectedLng });
}

function distanceMetersBetweenPoints(a, b) {
  const toRadians = (value) => (value * Math.PI) / 180;
  const earthRadiusMeters = 6371000;
  const lat1 = toRadians(Number(a.lat));
  const lng1 = toRadians(Number(a.lng));
  const lat2 = toRadians(Number(b.lat));
  const lng2 = toRadians(Number(b.lng));
  const deltaLat = lat2 - lat1;
  const deltaLng = lng2 - lng1;
  const sinLat = Math.sin(deltaLat / 2);
  const sinLng = Math.sin(deltaLng / 2);
  const haversine = sinLat * sinLat + Math.cos(lat1) * Math.cos(lat2) * sinLng * sinLng;
  const c = 2 * Math.atan2(Math.sqrt(haversine), Math.sqrt(1 - haversine));
  return earthRadiusMeters * c;
}

function firstValidPoint(line) {
  for (const segment of line.segments || []) {
    for (const point of segment || []) {
      if (isValidLatLng(point)) return point;
    }
  }
  return null;
}

function isValidLatLng(point) {
  const lat = Number(point?.lat);
  const lng = Number(point?.lng);
  return Number.isFinite(lat) && Number.isFinite(lng) && lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
}

function roundRect(ctx, x, y, width, height, radius) {
  const r = Math.min(radius, width / 2, height / 2);
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + width, y, x + width, y + height, r);
  ctx.arcTo(x + width, y + height, x, y + height, r);
  ctx.arcTo(x, y + height, x, y, r);
  ctx.arcTo(x, y, x + width, y, r);
  ctx.closePath();
}

function handleMapPointer(event) {
  if (state.mapDragging) return;
  const tooltip = $("mapTooltip");
  const canvas = $("adminMapCanvas");
  if (!tooltip || !canvas) return;
  const rect = canvas.getBoundingClientRect();
  const x = event.clientX - rect.left;
  const y = event.clientY - rect.top;
  const marker = state.mapMarkers
    .map((item) => ({
      item,
      distance: Math.hypot(item.x - x, item.y - y),
    }))
    .filter((entry) => entry.distance <= 24)
    .sort((a, b) => a.distance - b.distance)[0]?.item;
  if (!marker) {
    tooltip.classList.add("is-hidden");
    return;
  }
  if (marker.type === "user") {
    const user = marker.user || {};
    tooltip.replaceChildren(
      createElement("strong", { textContent: text(user.fullName || user.name || user.email || "Utilisateur", "") }),
      createElement("span", { textContent: text(user.role || "utilisateur", "") }),
      createElement("span", { textContent: `GPS ${text(gpsAgeLabel(user.location?.timestamp), "")}` }),
    );
  } else {
    const trip = marker.trip;
    tooltip.replaceChildren(
      createElement("strong", { textContent: `${text(trip.displayCode, "")} - ${text(trip.ownerName, "")}` }),
      createElement("span", { textContent: `${number(trip.speedKmh, 1)} km/h - ${number(trip.observers)} observateur(s)` }),
      createElement("span", { textContent: `GPS ${text(gpsAgeLabel(trip.liveLocation?.timestamp || trip.lastUpdatedAt), "")}` }),
    );
  }
  tooltip.style.left = `${Math.min(rect.width - 220, Math.max(12, x + 14))}px`;
  tooltip.style.top = `${Math.max(12, y + 14)}px`;
  tooltip.classList.remove("is-hidden");
}

function renderEvents(events) {
  $("eventCount").textContent = `${events.length} evenement(s)`;
  const list = $("eventsList");
  list.replaceChildren(
    ...(events.length
      ? events.map((event) => {
          const item = createElement("div", {
            className: "event-item",
            style: { "border-left-color": color(event.colorValue) },
          });
          appendChildren(
            item,
            createElement("strong", { textContent: text(event.title, "") }),
            createElement("span", { textContent: text(event.subtitle, "") }),
            createElement("span", { textContent: `${dateTime(event.timestamp)} - ${text(event.iconKey, "")}` }),
          );
          return item;
        })
      : [createElement("p", { textContent: "Aucun evenement pour le moment." })]),
  );
}

function metricRow([label, value]) {
  return createMetricRow(label, value);
}

function linePill(label, colorValue) {
  return createLinePill(label, colorValue);
}

function emptyRow(colspan, label) {
  const row = createElement("tr");
  row.appendChild(createElement("td", { attributes: { colspan }, textContent: label }));
  return row;
}

function tripDetailRow(trip, colspan) {
  const messages = Array.isArray(trip.messages) ? trip.messages : [];
  const totalMessages = tripMessageCount(trip);
  const routeLabel = `${text(trip.originLabel, "Depart")} -> ${text(
    trip.destinationLabel,
    "Arrivee",
  )}`;
  const chatSubtitle =
    totalMessages > messages.length
      ? `${number(messages.length)} derniers sur ${number(totalMessages)}`
      : messages.length
        ? `${number(messages.length)} message(s) transmis`
        : "aucun message transmis";
  const row = createElement("tr", { className: "trip-detail-row" });
  const cell = createElement("td", { attributes: { colspan } });
  const card = createElement("div", { className: "trip-detail-card" });
  const grid = createElement("div", { className: "trip-detail-grid" });
  appendChildren(
    grid,
    detailMetric("Trajet", `${trip.displayCode || "-"} - ${routeLabel}`),
    detailMetric("Statut", trip.status || "-"),
    detailMetric("Likes", number(tripLikeCount(trip))),
    detailMetric("Messages chat", number(tripMessageCount(trip))),
    detailMetric("Note", `${number(trip.ratingAverage, 1)} / 5 (${number(trip.ratingCount)} avis)`),
    detailMetric("Distance", `${distanceKm(trip.distanceKm)} / ${distanceKm(trip.routeDistanceKm)}`),
  );
  appendChildren(
    card,
    grid,
    createElement("div", { className: "trip-detail-note" }),
  );
  const noteBlock = card.children[1];
  appendChildren(
    noteBlock,
    createElement("strong", { textContent: "Note trajet" }),
    createElement("span", { textContent: text(trip.note, "Aucune note.") }),
  );
  const systemBlock = createElement("div", { className: "trip-detail-note" });
  appendChildren(
    systemBlock,
    createElement("strong", { textContent: "Dernier message systeme" }),
    createElement("span", { textContent: text(trip.lastSystemMessage, "Aucun message systeme.") }),
  );
  const chat = createElement("div", { className: "trip-chat" });
  const chatTitle = createElement("div", { className: "trip-chat-title" });
  appendChildren(
    chatTitle,
    createElement("strong", { textContent: "Chat du trajet" }),
    createElement("span", { textContent: text(chatSubtitle, "") }),
  );
  appendChildren(chat, chatTitle, tripMessagesHtml(messages));
  appendChildren(card, systemBlock, chat);
  cell.appendChild(card);
  row.appendChild(cell);
  return row;
}

function detailMetric(label, value) {
  const container = createElement("div", { className: "detail-metric" });
  appendChildren(
    container,
    createElement("span", { textContent: text(label, "") }),
    createElement("strong", { textContent: text(value, "") }),
  );
  return container;
}

function tripMessagesHtml(messages) {
  const fragment = document.createDocumentFragment();
  if (!messages.length) {
    fragment.appendChild(createElement("p", { className: "muted-text", textContent: "Aucun message archive pour ce trajet." }));
    return fragment;
  }
  for (const message of messages) {
    const item = createElement("div", { className: `trip-message ${message.isSystem ? "is-system" : ""}`.trim() });
    const header = createElement("div");
    appendChildren(
      header,
      createElement("strong", { textContent: text(message.authorName, "Systeme") }),
      createElement("small", { textContent: `${text(message.role, "-")} - ${dateTime(message.createdAt)}` }),
    );
    appendChildren(item, header, createElement("p", { textContent: text(message.content, "") }));
    fragment.appendChild(item);
  }
  return fragment;
}

async function stopTrip(tripId, reason) {
  const dashboard = await api(`/admin/trips/${encodeURIComponent(tripId)}/stop`, {
    method: "POST",
    body: JSON.stringify({ reason }),
  });
  updateDashboard(dashboard);
}

async function toggleUser(userId) {
  const dashboard = await api(`/admin/users/${encodeURIComponent(userId)}/status`, {
    method: "PATCH",
    body: JSON.stringify({}),
  });
  updateDashboard(dashboard);
}

async function updateReportStatus(reportId, status) {
  const dashboard = await api(`/admin/reports/${encodeURIComponent(reportId)}/status`, {
    method: "PATCH",
    body: JSON.stringify({ status }),
  });
  updateDashboard(dashboard);
}

async function sendNotification(event) {
  event.preventDefault();
  const dashboard = await api("/admin/notifications", {
    method: "POST",
    body: JSON.stringify({
      targetType: $("targetType").value,
      targetId: $("targetId").value.trim(),
      title: $("notificationTitle").value.trim(),
      body: $("notificationBody").value.trim(),
    }),
  });
  updateDashboard(dashboard);
}

document.addEventListener("click", async (event) => {
  const mapLineButton = event.target.closest("[data-map-line]");
  if (mapLineButton) {
    state.mapSelectedLine = mapLineButton.dataset.mapLine || "";
    $("mapLineFilter").value = state.mapSelectedLine;
    renderAdminMap(state.dashboard || {});
    return;
  }

  const detailsButton = event.target.closest("[data-trip-details]");
  if (detailsButton) {
    const tripId = detailsButton.dataset.tripDetails;
    if (state.expandedTrips.has(tripId)) {
      state.expandedTrips.delete(tripId);
    } else {
      state.expandedTrips.add(tripId);
    }
    if (state.dashboard) {
      renderTrips(state.dashboard.liveTrips || []);
      renderTripHistory(state.dashboard.trips || []);
    }
    return;
  }

  const stopButton = event.target.closest("[data-stop-trip]");
  if (stopButton) {
    const tripId = stopButton.dataset.stopTrip;
    const trip = (state.dashboard?.liveTrips || []).find((item) => item.id === tripId);
    state.stopTripId = tripId;
    state.stopTripLabel = trip
      ? `${trip.displayCode} - ${trip.ownerName}`
      : tripId;
    $("stopTripLabel").textContent = state.stopTripLabel;
    $("stopReason").value = `Trajet arrete par un administrateur Piwibus : anomalie constatee sur le suivi live.`;
    $("stopDialog").showModal();
    return;
  }

  const userButton = event.target.closest("[data-toggle-user]");
  if (userButton) {
    userButton.disabled = true;
    try {
      await toggleUser(userButton.dataset.toggleUser);
    } finally {
      userButton.disabled = false;
    }
    return;
  }

  const reportButton = event.target.closest("[data-report-status]");
  if (reportButton) {
    reportButton.disabled = true;
    try {
      await updateReportStatus(
        reportButton.dataset.reportStatus,
        reportButton.dataset.status,
      );
    } finally {
      reportButton.disabled = false;
    }
  }
});

$("confirmStopButton").addEventListener("click", async () => {
  const button = $("confirmStopButton");
  button.disabled = true;
  try {
    await stopTrip(state.stopTripId, $("stopReason").value.trim());
    $("stopDialog").close();
  } finally {
    button.disabled = false;
  }
});

document.querySelectorAll(".tab").forEach((tab) => {
  tab.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((item) => item.classList.remove("is-active"));
    document.querySelectorAll(".panel").forEach((panel) => panel.classList.add("is-hidden"));
    tab.classList.add("is-active");
    $(tab.dataset.target).classList.remove("is-hidden");
    if (tab.dataset.target === "mapPanel") {
      loadMapCatalog();
      requestAnimationFrame(() => renderAdminMap(state.dashboard || {}));
    }
  });
});

$("loginForm").addEventListener("submit", login);
$("refreshButton").addEventListener("click", refreshDashboard);
$("logoutButton").addEventListener("click", () => {
  if (state.csrfToken) {
    api("/admin/auth/logout", { method: "POST" }).catch(() => {});
  }
  state.csrfToken = "";
  if (state.eventSource) {
    state.eventSource.close();
    state.eventSource = null;
  }
  if (state.socket) {
    state.socket.close();
    state.socket = null;
  }
  showLogin();
});
$("notificationForm").addEventListener("submit", sendNotification);
$("userSearch").addEventListener("input", () => renderUsers(state.dashboard?.users || []));
$("lineSearch").addEventListener("input", () => renderCatalog(state.dashboard || {}));
$("mapLineFilter").addEventListener("change", () => {
  state.mapSelectedLine = $("mapLineFilter").value;
  renderAdminMap(state.dashboard || {});
});
$("mapUserRadius").addEventListener("change", () => {
  state.mapUserRadiusMeters = Number($("mapUserRadius").value || 1000);
  renderAdminMap(state.dashboard || {});
});
$("mapLiveOnly").addEventListener("change", () => renderAdminMap(state.dashboard || {}));
$("mapFollowLive").addEventListener("change", () => renderAdminMap(state.dashboard || {}));
$("mapRefreshButton").addEventListener("click", () => loadMapCatalog({ force: true }));
$("mapZoomInButton").addEventListener("click", () => adjustMapZoom(1));
$("mapZoomOutButton").addEventListener("click", () => adjustMapZoom(-1));
$("mapNorthButton").addEventListener("click", resetMapNorth);
$("mapCenterButton").addEventListener("click", recenterMap);
$("mapTilesButton").addEventListener("click", toggleMapTiles);
$("mapExpandButton").addEventListener("click", () => {
  void toggleMapExpanded();
});
$("adminMapCanvas").addEventListener("pointerdown", startMapDrag);
$("adminMapCanvas").addEventListener("pointermove", moveMapDrag);
$("adminMapCanvas").addEventListener("pointerup", endMapDrag);
$("adminMapCanvas").addEventListener("pointercancel", endMapDrag);
$("adminMapCanvas").addEventListener("lostpointercapture", (event) => {
  if (state.mapDragPointerId === event.pointerId) {
    state.mapDragging = false;
    state.mapDragPointerId = null;
    $("adminMapCanvas")?.classList.remove("is-dragging");
  }
});
$("adminMapCanvas").addEventListener("keydown", (event) => {
  const step = event.shiftKey ? 180 : 80;
  if (event.key === "ArrowLeft") {
    panMapBy(-step, 0);
  } else if (event.key === "ArrowRight") {
    panMapBy(step, 0);
  } else if (event.key === "ArrowUp") {
    panMapBy(0, -step);
  } else if (event.key === "ArrowDown") {
    panMapBy(0, step);
  } else {
    return;
  }
  event.preventDefault();
});
$("adminMapCanvas").addEventListener("mousemove", handleMapPointer);
$("adminMapCanvas").addEventListener("mouseleave", () => {
  $("mapTooltip").classList.add("is-hidden");
});
document.addEventListener("fullscreenchange", () => {
  state.mapExpanded = document.fullscreenElement === $("adminMapShell");
  $("adminMapShell")?.classList.toggle("is-expanded", false);
  updateMapControlState();
  requestAnimationFrame(() => renderAdminMap(state.dashboard || {}));
});
window.addEventListener("resize", () => renderAdminMap(state.dashboard || {}));

refreshDashboard()
  .then(() => {
    connectRealtime();
    loadMapCatalog();
  })
  .catch(() => showLogin());
