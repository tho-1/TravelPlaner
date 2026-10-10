"use strict";

/* Travel Planner — the native HTML frontend (Phase 3).
   Vanilla JS, no build step. Talks to the FastAPI
   backend in api.py; every filter is applied server-side
   so the filter semantics (a filter may only remove rows
   whose field is populated) live in one place. */

const view = document.getElementById("view");
const statusEl = document.getElementById("status");
const sourceEl = document.getElementById("source");

function setStatus(message) {
  statusEl.textContent = message;
}

function setSource(source) {
  sourceEl.textContent = source === "turso"
    ? "data: Turso"
    : "data: workbook (Turso unreachable)";
}

async function api(path, options) {
  const response = await fetch("/api" + path, options);
  if (!response.ok) {
    let detail = response.statusText;
    try {
      const body = await response.json();
      detail = body.detail || detail;
    } catch (err) { /* keep the status text */ }
    throw new Error(`${response.status} ${detail}`);
  }
  return response.json();
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function pill(on, label) {
  return `<span class="pill${on ? " on" : ""}">${escapeHtml(label)}</span>`;
}

function showError(err) {
  view.innerHTML = `<p class="error">${escapeHtml(err.message)}</p>`;
}

/* ── router ─────────────────────────────────────────── */

function route() {
  const hash = location.hash || "#/";
  const [_, page, ...rest] = hash.split("/");
  document.querySelectorAll("[data-nav]").forEach((link) => {
    link.classList.toggle("active", link.dataset.nav === page);
  });
  if (page === "destination") {
    renderDestination(decodeURIComponent(rest.join("/")));
  } else if (page === "trips") {
    renderTrips();
  } else if (page === "weekend") {
    renderWeekend();
  } else {
    renderCatalogue();
  }
}

window.addEventListener("hashchange", route);

/* ── catalogue ──────────────────────────────────────── */

const catalogueState = {
  q: "", country: "", continent: "",
  visited: false, favourite: false, researched: false,
  showVisited: false, showFavourite: false, showResearched: false,
  limit: 0,
};

async function renderCatalogue() {
  view.innerHTML = `
    <form class="filters" id="filter-form">
      <label>Search
        <input name="q" type="search" value="${escapeHtml(catalogueState.q)}" placeholder="destination…">
      </label>
      <label>Country
        <input name="country" type="text" value="${escapeHtml(catalogueState.country)}">
      </label>
      <label>Continent
        <input name="continent" type="text" value="${escapeHtml(catalogueState.continent)}">
      </label>
      <label class="check"><input name="visited" type="checkbox" ${catalogueState.showVisited ? "checked" : ""}> visited</label>
      <label class="check"><input name="favourite" type="checkbox" ${catalogueState.showFavourite ? "checked" : ""}> favourite</label>
      <label class="check"><input name="researched" type="checkbox" ${catalogueState.showResearched ? "checked" : ""}> to be researched</label>
      <label>Limit
        <input name="limit" type="number" min="0" value="${catalogueState.limit}" style="width:5.5rem">
      </label>
      <button type="submit">Apply</button>
    </form>
    <p class="loading">Loading destinations…</p>`;

  document.getElementById("filter-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const form = event.target;
    catalogueState.q = form.q.value.trim();
    catalogueState.country = form.country.value.trim();
    catalogueState.continent = form.continent.value.trim();
    catalogueState.showVisited = form.visited.checked;
    catalogueState.showFavourite = form.favourite.checked;
    catalogueState.showResearched = form.researched.checked;
    catalogueState.limit = parseInt(form.limit.value, 10) || 0;
    loadCatalogue();
  });

  await loadCatalogue();
}

async function loadCatalogue() {
  const params = new URLSearchParams();
  if (catalogueState.q) params.set("q", catalogueState.q);
  if (catalogueState.country) params.set("country", catalogueState.country);
  if (catalogueState.continent) params.set("continent", catalogueState.continent);
  if (catalogueState.showVisited) params.set("visited", "true");
  if (catalogueState.showFavourite) params.set("favourite", "true");
  if (catalogueState.showResearched) params.set("researched", "true");
  if (catalogueState.limit > 0) params.set("limit", String(catalogueState.limit));

  try {
    const body = await api("/destinations?" + params.toString());
    const rows = body.destinations;
    const dropped = body.count === 0
      ? "No destinations match — every filter only removes rows whose field is populated."
      : "";
    view.innerHTML = `
      <p class="count">${body.count} destination${body.count === 1 ? "" : "s"}${dropped ? " — " + escapeHtml(dropped) : ""}</p>
      <table class="data">
        <thead><tr>
          <th>Destination</th><th>Country</th><th>Continent</th>
          <th>Visited</th><th>Favourite</th><th>Prio</th>
          <th>Safety</th><th>Cost/day</th><th>Flight h</th>
        </tr></thead>
        <tbody>
          ${rows.map((row) => `
            <tr data-name="${escapeHtml(row.destination)}">
              <td>${escapeHtml(row.destination)}</td>
              <td>${escapeHtml(row.country ?? "")}</td>
              <td>${escapeHtml(row.continent ?? "")}</td>
              <td>${pill(row.visited, row.visited ? "yes" : "no")}</td>
              <td>${pill(row.favourite, row.favourite ? "★" : "—")}</td>
              <td>${escapeHtml(row.prio ?? "")}</td>
              <td>${escapeHtml(row.safety_rating ?? "")}</td>
              <td>${escapeHtml(row.avg_cost_day ?? "")}</td>
              <td>${escapeHtml(row.flight_time_fra ?? "")}</td>
            </tr>`).join("")}
        </tbody>
      </table>`;
    view.querySelectorAll("tr[data-name]").forEach((tr) => {
      tr.addEventListener("click", () => {
        location.hash = "#/destination/" + encodeURIComponent(tr.dataset.name);
      });
    });
  } catch (err) {
    showError(err);
  }
}

/* ── destination detail ─────────────────────────────── */

async function renderDestination(name) {
  view.innerHTML = `<p class="loading">Loading ${escapeHtml(name)}…</p>`;
  try {
    const [detail, list] = await Promise.all([
      api("/destinations/" + encodeURIComponent(name)),
      api("/destinations?limit=1"),
    ]);
    setSource(list.source ?? "workbook");

    const fields = detail.fields || {};
    const number = (value) => (value === null || value === undefined || value === "" ? "—" : escapeHtml(value));
    const metrics = `
      <div class="metrics">
        <div class="metric"><b>${number(fields["Continent"])}</b><span>continent</span></div>
        <div class="metric"><b>${number(fields["Country"])}</b><span>country</span></div>
        <div class="metric"><b>${number(fields["Safety Rating (10 = safest)"])}</b><span>safety (10 = safest)</span></div>
        <div class="metric"><b>${number(fields["Avg. Cost/Day (3* Hotel & Food)"])}</b><span>cost/day</span></div>
        <div class="metric"><b>${number(fields["Flight Time to Frankfurt (hours)"])}</b><span>flight hours from FRA</span></div>
        <div class="metric"><b>${number(fields["Malaria risk?"] ? "yes" : "no")}</b><span>malaria risk</span></div>
      </div>`;

    const editables = `
      <div class="editrow">
        <label><input type="checkbox" id="edit-favourite" ${fields["In näherer Auswahl 2025?"] ? "checked" : ""}> favourite</label>
        <label><input type="checkbox" id="edit-visited" ${fields["Visited?"] ? "checked" : ""}> visited</label>
        <label><input type="checkbox" id="edit-researched" ${fields["To be researched"] ? "checked" : ""}> to be researched</label>
        <label>Prio <input type="number" id="edit-prio" value="${number(fields["Prio Thorsten"])}" style="width:4.5rem"></label>
        <label>Comment <input type="text" id="edit-comment" value="${escapeHtml(fields["Comment"] ?? "")}" size="40"></label>
        <button id="edit-save" class="secondary" type="button">Save</button>
      </div>`;

    const allFields = (detail.columns || [])
      .map(([column, value]) => `<dt>${escapeHtml(column)}</dt><dd>${escapeHtml(value ?? "")}</dd>`)
      .join("");

    view.innerHTML = `
      <div class="destination">
        <h2>${escapeHtml(detail.destination)}</h2>
        ${metrics}
        ${editables}
        <h3>All fields</h3>
        <dl class="fields">${allFields}</dl>
      </div>`;

    document.getElementById("edit-save").addEventListener("click", async () => {
      const patch = {
        favourite: document.getElementById("edit-favourite").checked,
        visited: document.getElementById("edit-visited").checked,
        to_be_researched: document.getElementById("edit-researched").checked,
        prio: parseInt(document.getElementById("edit-prio").value, 10) || null,
        comment: document.getElementById("edit-comment").value,
      };
      try {
        const result = await api("/destinations/" + encodeURIComponent(name), {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(patch),
        });
        setStatus(result.written
          ? "Saved."
          : "Some writes failed: " + JSON.stringify(result.results));
        renderDestination(name);
      } catch (err) {
        showError(err);
      }
    });
  } catch (err) {
    showError(err);
  }
}

/* ── trips ──────────────────────────────────────────── */

async function renderTrips() {
  view.innerHTML = `
    <form class="filters" id="trip-form">
      <label>New trip
        <input name="name" type="text" placeholder="Trip name" required>
      </label>
      <button type="submit">Create</button>
    </form>
    <p class="loading">Loading trips…</p>`;

  document.getElementById("trip-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const name = event.target.name.value.trim();
    if (!name) return;
    try {
      await api("/trips", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name }),
      });
      setStatus(`Trip "${name}" created.`);
      renderTrips();
    } catch (err) {
      showError(err);
    }
  });

  try {
    const body = await api("/trips");
    const trips = body.trips || [];
    view.innerHTML = `
      <form class="filters" id="trip-form">
        <label>New trip
          <input name="name" type="text" placeholder="Trip name" required>
        </label>
        <button type="submit">Create</button>
      </form>
      <p class="count">${trips.length} trip${trips.length === 1 ? "" : "s"}</p>
      ${trips.map((trip) => `
        <div class="trip" data-id="${escapeHtml(trip.id)}">
          <h3>${escapeHtml(trip.name)}</h3>
          <div class="meta">
            created ${escapeHtml(trip.created ?? "")} ·
            ${(trip.variants || []).length} variant(s) ·
            <a href="#/trips/${encodeURIComponent(trip.id)}">open</a> ·
            <button class="secondary delete" type="button">delete</button>
          </div>
        </div>`).join("") || `<p class="empty">No trips yet.</p>`}`;

    view.querySelectorAll("form#trip-form").forEach((form) => {
      form.addEventListener("submit", async (event) => {
        event.preventDefault();
        const name = form.name.value.trim();
        if (!name) return;
        try {
          await api("/trips", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ name }),
          });
          setStatus(`Trip "${name}" created.`);
          renderTrips();
        } catch (err) {
          showError(err);
        }
      });
    });
    view.querySelectorAll(".trip .delete").forEach((button) => {
      button.addEventListener("click", async (event) => {
        event.stopPropagation();
        const card = button.closest(".trip");
        const id = card.dataset.id;
        if (!confirm(`Delete this trip?`)) return;
        try {
          await api("/trips/" + encodeURIComponent(id), { method: "DELETE" });
          setStatus("Trip deleted.");
          renderTrips();
        } catch (err) {
          showError(err);
        }
      });
    });
  } catch (err) {
    showError(err);
  }
}

async function renderTripDetail(tripId) {
  view.innerHTML = `<p class="loading">Loading trip…</p>`;
  try {
    const trip = await api("/trips/" + encodeURIComponent(tripId));
    const variants = (trip.variants || []).map((variant) => {
      const stops = (variant.stops || []).map((stop) => `
        <div class="stop">
          <b>${escapeHtml(stop.ref?.name ?? "Unnamed stop")}</b>
          ${escapeHtml(stop.ref?.country ? ` (${stop.ref.country})` : "")}
          <div class="flight">
            ${escapeHtml(stop.arrival_date ?? "")}${stop.arrival_date && stop.departure_date ? " → " : ""}${escapeHtml(stop.departure_date ?? "")}
            · ${escapeHtml(stop.nights ?? 0)} night(s) · ${escapeHtml(stop.role ?? "stop")}
            ${stop.notes ? " · " + escapeHtml(stop.notes) : ""}
          </div>
        </div>`).join("");
      const legs = (variant.legs || []).map((leg) =>
        `<div class="leg">${escapeHtml(leg.mode ?? "flight")}${leg.note ? " — " + escapeHtml(leg.note) : ""}</div>`).join("");
      return `
        <div class="trip">
          <h3>${escapeHtml(variant.name)}</h3>
          <div class="meta">rating ${escapeHtml(variant.rating ?? "—")} · months ${escapeHtml((variant.months || []).join(", ") || "—")}</div>
          ${variant.notes ? `<div class="notes">${escapeHtml(variant.notes)}</div>` : ""}
          ${stops}${legs}
        </div>`;
    }).join("");
    view.innerHTML = `
      <div class="destination">
        <h2>${escapeHtml(trip.name)}</h2>
        <p class="count">created ${escapeHtml(trip.created ?? "")}</p>
        ${variants || `<p class="empty">No variants.</p>`}
      </div>`;
  } catch (err) {
    showError(err);
  }
}

/* ── weekend finder ─────────────────────────────────── */

async function renderWeekend() {
  view.innerHTML = `
    <form class="filters" id="weekend-form">
      <label>Friday
        <input name="friday" type="date">
      </label>
      <label>Out Fri from
        <input name="friday_from" type="time" value="14:00">
      </label>
      <label>Sat before
        <input name="saturday_before" type="time" value="12:00">
      </label>
      <label>Sat back after
        <input name="saturday_return_after" type="time" value="12:00">
      </label>
      <label>Mon back before
        <input name="monday_return_before" type="time" value="09:00">
      </label>
      <button type="submit">Search</button>
    </form>
    <p class="loading">Search the Fraport boards for a weekend…</p>`;

  document.getElementById("weekend-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.target;
    const params = new URLSearchParams();
    if (form.friday.value) params.set("friday", form.friday.value);
    params.set("friday_from", form.friday_from.value || "14:00");
    params.set("saturday_before", form.saturday_before.value || "12:00");
    params.set("saturday_return_after", form.saturday_return_after.value || "12:00");
    params.set("monday_return_before", form.monday_return_before.value || "09:00");
    view.innerHTML = `<p class="loading">Fetching flights from Fraport…</p>`;
    try {
      const report = await api("/weekend?" + params.toString());
      const city = (result) => `
        <div class="weekend-city">
          <h3>${escapeHtml(result.label)}</h3>
          <div class="meta">${result.options.length} option(s) · airports ${escapeHtml(result.airports.join(", "))}</div>
          ${result.options.map((option) => `
            <div class="flight">
              <b>${escapeHtml(option.city)}</b> — ${escapeHtml(option.nights)} night(s)
              · out ${escapeHtml(option.outbound.flight_no)} (${escapeHtml(option.outbound_airline)}) ${escapeHtml(option.outbound.origin)}→${escapeHtml(option.outbound.destination)} ${escapeHtml(option.outbound.departure.slice(11, 16))}
              · back ${escapeHtml(option.return.flight_no)} (${escapeHtml(option.return_airline)}) ${escapeHtml(option.return.departure.slice(11, 16))}
              ${option.notes ? " · " + escapeHtml(option.notes) : ""}
            </div>`).join("")}
        </div>`;
      view.innerHTML = `
        <p class="count">${report.weekend} — ${report.city_count} cit${report.city_count === 1 ? "y" : "ies"}, ${report.option_count} option(s) from ${report.outbound_total} outbound / ${report.return_total} return flights</p>
        ${report.cities.map(city).join("") || `<p class="empty">No matching weekend trips.</p>`}
        ${report.one_way_only.length ? `<h3>One-way only (no return within the windows)</h3>${report.one_way_only.map(city).join("")}` : ""}
        ${report.notes.length ? `<p class="notes">${report.notes.map(escapeHtml).join("<br>")}</p>` : ""}
        ${Object.keys(report.outbound_rejected_airlines || {}).length ? `<p class="notes">Rejected airlines (no benefits): ${escapeHtml(Object.entries(report.outbound_rejected_airlines).map(([name, count]) => `${name} (${count})`).join(", "))}</p>` : ""}`;
    } catch (err) {
      showError(err);
    }
  });
}

/* ── boot ───────────────────────────────────────────── */

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {
    /* offline support is best-effort */
  });
}

route();
