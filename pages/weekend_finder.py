"""Weekend trip finder: where can you fly from Frankfurt for the weekend?

Answers the question directly — a list of ``City (Country)`` entries, one row
per city, each expandable to the flight pairs that work.

What it needs from the outside world
------------------------------------
Only flights. Which source provides them is decided at runtime and shown in the
sidebar: today that is the CSV upload, because both live boards we tried are
unreachable from plain HTTP (see ``timetable`` for the evidence and
``timetable.provider_status()`` for the machine-readable version). Everything
else — the time windows, the airline filter, the city list — works the same
whichever source answered.

The logic lives in ``weekend_match`` and is tested without a browser; this file
is only the Streamlit surface.
"""

from __future__ import annotations

from datetime import date, time

import pandas as pd
import streamlit as st

import airline_benefits
import airport_city
import timetable
import weekend_match as wm

HOME = wm.HOME_AIRPORT

#: How far ahead the finder looks by default. A weekend's schedule is only
#: useful once published, so asking for less tends to return an empty board.
MIN_LEAD_DAYS = 5

CSV_TEMPLATE = """flight_no,airline,origin,destination,departure,arrival
LH1000,Lufthansa,FRA,BCN,09.10.2026 15:05,09.10.2026 17:05
LH1002,Lufthansa,BCN,FRA,11.10.2026 16:40,11.10.2026 18:35
"""


def _time_input(label: str, default: time, key: str) -> time:
    value = st.time_input(label, value=default, key=key, step=900)
    return value if isinstance(value, time) else default


def _default_friday() -> date:
    today = date.today()
    return wm.next_friday(today, minimum_days_ahead=MIN_LEAD_DAYS)


def render_weekend_finder() -> None:
    st.title("🗓️ Weekend trip finder")
    st.caption(
        f"Direct flights from {HOME}, out and back, inside your time windows. "
        f"Only airlines marked as having benefits."
    )

    source = _render_data_source()
    if source is None:
        return

    friday = st.date_input(
        "Weekend of (Friday)",
        value=_default_friday(),
        key="weekend_friday",
        help="Pick the Friday. Saturday, Sunday and the Monday return are derived.",
    )
    if not isinstance(friday, date):
        return
    weekend = wm.Weekend(friday=friday)

    with st.expander("Time windows", expanded=False):
        st.caption(
            "Outbound: Friday from the first time, or Saturday before the "
            "second. Return: Saturday after the third, Sunday, or Monday before "
            "the fourth."
        )
        col_a, col_b, col_c, col_d = st.columns(4)
        with col_a:
            friday_from = _time_input("Out Fri from", time(14, 0), "win_fri_from")
        with col_b:
            saturday_before = _time_input("Out Sat before", time(12, 0),
                                          "win_sat_before")
        with col_c:
            saturday_after = _time_input("Back Sat after", time(12, 0),
                                         "win_sat_after")
        with col_d:
            monday_before = _time_input("Back Mon before", time(9, 0),
                                        "win_mon_before")
        sunday_limited = st.checkbox(
            "Limit Sunday returns too", value=False,
            key="win_sun_limited",
            help="Off means any Sunday return counts.",
        )
        sunday_until = (time(20, 0) if sunday_limited else None)

    windows = wm.Windows(
        friday_from=friday_from,
        saturday_before=saturday_before,
        saturday_return_after=saturday_after,
        monday_return_before=monday_before,
        sunday_return_until=sunday_until,
    )
    st.caption(f"`{windows.describe()}`")

    flags = airline_benefits.load_benefit_flags()
    st.caption(airline_benefits.benefit_summary(flags))
    _render_benefit_source()

    if not st.button("🔎 Find weekends", type="primary", width="stretch"):
        return

    with st.spinner("Matching flights…"):
        report = _run(source, weekend, windows, flags)

    _render_notes(report, windows)
    if report.city_count == 0:
        _render_empty(report, windows)
        return
    _render_cities(report, windows)


# ── the data source ──────────────────────────────────────────────────────────

def _render_data_source():
    """Pick a provider. Returns ``None`` when there is nothing to search."""
    usable = timetable.available_providers()
    csv_only = [p for p in usable if p.name == "csv"]

    if not usable:
        st.error("No flight data source is available. See `timetable.py`.")
        return None

    with st.expander("Flight data source", expanded=len(usable) < 2):
        st.caption(
            "Only airlines you have marked as having benefits count. Data "
            "source currently in use: **"
            + ", ".join(p.name for p in usable) + "**."
        )
        _render_blocked_sources()

        departures_csv = ""
        arrivals_csv = ""
        if csv_only:
            st.markdown("**Upload your flight data (CSV)**")
            st.caption(
                "Two files, or leave one empty. Columns: "
                "`flight_no, airline, origin, destination, departure, arrival` "
                "— `operated_by` is used when present, because benefits follow "
                "the operating carrier. Times may be `15:05` or "
                "`09.10.2026 15:05`."
            )
            col_dep, col_arr = st.columns(2)
            with col_dep:
                up_dep = st.file_uploader("Departures from FRA", type=["csv"],
                                          key="weekend_dep_csv")
            with col_arr:
                up_arr = st.file_uploader("Arrivals into FRA", type=["csv"],
                                          key="weekend_arr_csv")
            if up_dep is not None:
                departures_csv = up_dep.getvalue().decode("utf-8", "replace")
            if up_arr is not None:
                arrivals_csv = up_arr.getvalue().decode("utf-8", "replace")
            if departures_csv.strip() or arrivals_csv.strip():
                return timetable.CsvProvider(departures_csv, arrivals_csv)
            with st.expander("Or paste CSV", expanded=False):
                pasted_dep = st.text_area("Departures", key="weekend_dep_text",
                                          height=120)
                pasted_arr = st.text_area("Arrivals", key="weekend_arr_text",
                                          height=120)
                if pasted_dep.strip() or pasted_arr.strip():
                    return timetable.CsvProvider(pasted_dep, pasted_arr)
            st.info(
                "Upload or paste flight data to search. The template below is "
                "a working example — edit it with your own flights."
            )
            with st.expander("CSV template", expanded=False):
                st.code(CSV_TEMPLATE, language="csv")
            return None

    return usable[0]


def _render_blocked_sources() -> None:
    blocked = [row for row in timetable.provider_status() if not row["usable"]]
    if not blocked:
        return
    with st.expander(f"Data sources that are not available ({len(blocked)})"):
        for row in blocked:
            st.markdown(f"**{row['name']}** — not available")
            st.caption(row["reason"])


# ── search ───────────────────────────────────────────────────────────────────

def _run(provider, weekend: wm.Weekend, windows: wm.Windows,
         flags: dict[str, bool]) -> wm.MatchReport:
    try:
        return timetable.search_weekend(weekend, windows, provider, flags)
    except timetable.ProviderUnavailable as exc:
        st.error(str(exc))
        return wm.MatchReport(weekend=weekend, windows=windows,
                              notes=[str(exc)])


def _render_benefit_source() -> None:
    """Show which airlines qualify, and say which source they came from.

    Two cases, because the button means different things in each:

    * **Turso configured** — the database is read on every run and cached, so the
      only useful action is clearing that cache. The text names the real source,
      never a guess.
    * **Not configured** — the legacy Excel file is being used, and re-reading it
      is worth a button (it lives in another project, so it changes without this
      app noticing).
    """
    qualified = airline_benefits.benefit_names()
    source = airline_benefits.benefit_source_name()
    using_turso = airline_benefits.turso_configured()

    with st.expander(f"Airlines with benefits ({len(qualified)})", expanded=False):
        st.caption(f"Read from **{source}**. An airline qualifies when **any** of "
                   f"discount_eligible / business_class / confirmed_booking is "
                   f"`yes`. 'unknown' counts as no.")
        st.markdown(", ".join(qualified) if qualified else "_none yet_")

        if using_turso:
            if st.button("🔄 Re-read the benefits database"):
                with st.spinner("Reading…"):
                    import benefits_turso

                    benefits_turso.clear_cache()
                    _records, problems = benefits_turso.fetch_benefit_records(
                        use_cache=False)
                for problem in problems:
                    st.warning(problem)
                st.rerun()
            return

        path = airline_benefits.external_file_path()
        if not path.exists():
            st.info(
                f"No benefits database configured and no legacy file at `{path}`. "
                f"Set `TURSO_AUTH_TOKEN` (preferred) or "
                f"`{airline_benefits.EXTERNAL_FILE_ENV}`; until then the "
                f"`{airline_benefits.SHEET_NAME}` workbook sheet is used.")
            return

        st.caption(f"Legacy source: `{path}`. The benefits database is the "
                   f"intended source — set `TURSO_AUTH_TOKEN` to switch over.")
        if st.button("🔄 Re-read the benefits file"):
            with st.spinner("Reading…"):
                report = airline_benefits.import_benefits_file()
            for problem in report["problems"]:
                st.warning(problem)
            if report["read"]:
                st.success(
                    f"Read {report['read']} airlines, {report['qualified']} "
                    f"with benefits. Mirrored {report['written']} row(s) into the "
                    f"workbook.")
                st.rerun()
            else:
                st.warning("Nothing could be read — keeping the previous list.")


def _render_notes(report: wm.MatchReport, windows: wm.Windows) -> None:
    st.caption(f"Weekend {report.weekend.describe()} · {windows.describe()}")
    st.caption(
        f"{report.outbound_total} outbound and {report.return_total} inbound "
        f"flights read · {report.city_count} cities · "
        f"{report.option_count} flight pairs."
    )
    for note in report.notes:
        st.warning(note, icon="⚠️")
    rule = wm.describe_rule(report.outbound_rejected_airlines)
    if rule:
        st.caption(rule)


def _render_empty(report: wm.MatchReport, windows: wm.Windows) -> None:
    st.info(
        "No city has both a qualifying outbound and a qualifying return in "
        "this weekend with your windows.",
        icon="🔍",
    )
    if report.one_way_only:
        st.markdown("**One leg only** — widen a window or check the other side:")
        for city in report.one_way_only[:12]:
            st.markdown(f"- {city.label}")
    unmatched = _unmatched_carriers(report)
    if unmatched:
        with st.expander("Airlines in your data that have no benefit flag"):
            st.caption("If any of these should count, tick them in the "
                       f"`{airline_benefits.SHEET_NAME}` sheet of the workbook.")
            st.markdown(", ".join(unmatched))


def _unmatched_carriers(report: wm.MatchReport) -> list[str]:
    flags = airline_benefits.load_benefit_flags()
    names: list[str] = []
    for city in list(report.cities) + list(report.one_way_only):
        for flight in city.out_only + city.back_only:
            name = flight.operator_airline
            if name and name not in names:
                names.append(name)
    return airline_benefits.unmatched_airlines(names, flags)


def _render_cities(report: wm.MatchReport, windows: wm.Windows) -> None:
    st.markdown(f"### {report.city_count} destinations")

    show_catalogue_first = st.checkbox(
        "Catalogue destinations first", value=True,
        key="weekend_catalogue_first",
        help="Cities that have a page in this app are more useful, so they "
             "float to the top.",
    )
    cities = list(report.cities)
    if show_catalogue_first:
        cities.sort(key=lambda c: (not _is_catalogue(c), c.city))

    frame = _summary_frame(cities)
    st.dataframe(frame, use_container_width=True, hide_index=True,
                 column_config={
                     "City": st.column_config.TextColumn(width="large"),
                     "Options": st.column_config.NumberColumn(format="%d"),
                     "Earliest out": st.column_config.TextColumn(),
                     "Airlines": st.column_config.TextColumn(width="medium"),
                 })

    st.markdown("---")
    for city in cities:
        _render_city(city)

    if report.one_way_only:
        with st.expander(f"One-way only ({len(report.one_way_only)})",
                         expanded=False):
            st.caption(
                "These have a qualifying outbound or return but not both. "
                "Useful if you would travel by train or another airline one "
                "of the two ways."
            )
            for city in report.one_way_only:
                st.markdown(f"- **{city.label}** ({', '.join(sorted(city.airports))})")


def _is_catalogue(city: wm.CityResult) -> bool:
    return airport_city.match_catalogue(city.city, city.country) is not None


def _summary_frame(cities: list[wm.CityResult]) -> pd.DataFrame:
    rows = []
    for city in cities:
        airlines = sorted({o.outbound_airline for o in city.options}
                          | {o.return_airline for o in city.options})
        rows.append({
            "City": city.label,
            "Options": city.count,
            "Earliest out": city.options[0].out_flight.departure.strftime(
                "%a %H:%M"),
            "Nights": city.options[0].nights,
            "Airlines": ", ".join(airlines),
        })
    return pd.DataFrame(rows, columns=["City", "Options", "Earliest out",
                                       "Nights", "Airlines"])


def _render_city(city: wm.CityResult) -> None:
    catalogue_name = airport_city.match_catalogue(city.city, city.country)
    heading = f"**{city.label}**"
    if catalogue_name:
        st.markdown(f"{heading} — in your catalogue as *{catalogue_name}*")
    else:
        st.markdown(heading)

    airports = ", ".join(sorted(city.airports))
    st.caption(f"{airports} · {city.count} option{'s' if city.count != 1 else ''}")
    if city.unmapped_airports:
        st.caption(
            f"⚠️ {', '.join(sorted(city.unmapped_airports))} could not be "
            f"mapped to a city — the label above is the raw airport code."
        )

    for option in city.options:
        _render_option(option)


def _render_option(option: wm.TripOption) -> None:
    out_f, back_f = option.out_flight, option.back_flight
    nights = option.nights
    stay = f"{nights} night{'s' if nights != 1 else ''}"
    label = (f"{out_f.flight_no} {out_f.origin}→{out_f.destination} "
             f"{out_f.departure:%a %H:%M} · back {back_f.flight_no} "
             f"{back_f.origin}→{back_f.destination} {back_f.arrival:%a %H:%M} "
             f"· {stay}")
    with st.expander(label, expanded=False):
        columns = st.columns(4)
        with columns[0]:
            st.markdown("**Out**")
            st.write(f"{out_f.flight_no} · {out_f.operator_airline}")
            st.write(f"{out_f.departure:%a %d %b %H:%M}")
            st.write(f"→ {out_f.arrival:%a %d %b %H:%M}")
        with columns[1]:
            st.markdown("**Back**")
            st.write(f"{back_f.flight_no} · {back_f.operator_airline}")
            st.write(f"{back_f.departure:%a %d %b %H:%M}")
            st.write(f"→ {back_f.arrival:%a %d %b %H:%M}")
        with columns[2]:
            st.markdown("**Stay**")
            st.write(stay)
            if out_f.terminal:
                st.caption(f"Terminal {out_f.terminal}")
        with columns[3]:
            st.markdown("**Airlines**")
            st.write(out_f.operator_airline)
            if out_f.marketing_airline != out_f.operator_airline:
                st.caption(f"marketed as {out_f.marketing_airline}")


if __name__ == "__main__":  # pragma: no cover - manual run
    render_weekend_finder()