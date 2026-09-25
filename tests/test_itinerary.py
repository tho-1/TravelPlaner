"""Tests for the itinerary core package.

Dual-run: works under pytest AND as a plain script (`python tests/test_itinerary.py`)
because this project has no pytest dependency. Every test function is
collected by the __main__ runner below.
"""

from __future__ import annotations

import sys
import tempfile
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from itinerary import geo, itinerary as itin, map as itmap, models, sample, storage  # noqa: E402


# ── models ───────────────────────────────────────────────────────────────────

def test_normalize_roundtrip_keeps_invariants():
    trip = sample.make_sample_trip()
    norm = models.normalize_all({"schema_version": 99, "trips": [trip]})
    assert norm["schema_version"] == models.SCHEMA_VERSION
    assert len(norm["trips"]) == 1
    t = norm["trips"][0]
    assert t["name"] == "China Trip 2027"
    assert t["active_variant_id"] in {v["id"] for v in t["variants"]}
    for variant in t["variants"]:
        assert len(variant["legs"]) == len(variant["stops"]) - 1


def test_normalize_repairs_missing_legs_and_active_variant():
    raw = {"trips": [{"name": "X", "variants": [
        {"name": "V", "stops": [{"ref": {"kind": "custom", "name": "A"}},
                                {"ref": {"kind": "custom", "name": "B"}}]},
    ]}]}
    trip = models.normalize_trip(raw["trips"][0])
    v = trip["variants"][0]
    assert len(v["legs"]) == 1  # auto-inserted placeholder
    assert v["legs"][0]["mode"] == "flight"
    assert trip["active_variant_id"] == v["id"]


def test_normalize_drops_extra_legs():
    v = models.normalize_variant({"stops": [{"ref": {"name": "A"}}],
                                  "legs": [{"mode": "train"},
                                           {"mode": "bus"}]})
    assert len(v["legs"]) == 0  # 1 stop -> 0 legs


def test_make_and_find_helpers():
    trip = models.make_trip("T")
    v = trip["variants"][0]
    assert models.active_variant(trip) is v
    assert models.find_variant(trip, "nope") is None
    assert models.find_trip({"trips": [trip]}, trip["id"]) is trip


# ── stop / leg operations ────────────────────────────────────────────────────

def _variant_3_stops():
    v = models.make_variant("V", [
        models.make_stop(models.make_ref("gateway", "FRA", "Germany",
                                         50.11, 8.68), role="origin"),
        models.make_stop(models.make_ref("custom", "A", "China", 39.9, 116.4)),
        models.make_stop(models.make_ref("custom", "B", "China", 31.2, 121.5)),
    ], [models.make_leg("flight"), models.make_leg("train")])
    return v


def test_remove_stop_first_deletes_leg0_only():
    v = _variant_3_stops()
    itin.remove_stop(v, 0)
    assert [s["ref"]["name"] for s in v["stops"]] == ["A", "B"]
    assert len(v["legs"]) == 1
    assert v["legs"][0]["mode"] == "train"  # the FRA->A flight was removed


def test_remove_stop_middle_deletes_incoming_leg():
    v = _variant_3_stops()
    itin.remove_stop(v, 1)  # remove A: incoming leg FRA->A (legs[0]) dies
    assert [s["ref"]["name"] for s in v["stops"]] == ["FRA", "B"]
    assert len(v["legs"]) == 1
    # gap FRA->B inherits the old A->B train (incoming-leg removal policy)
    assert v["legs"][0]["mode"] == "train"


def test_move_stop_swap_keeps_gap_transport():
    v = _variant_3_stops()
    modes_before = [l["mode"] for l in v["legs"]]  # flight, train
    new_idx = itin.move_stop(v, 1, +1)  # A <-> B
    assert new_idx == 2
    assert [s["ref"]["name"] for s in v["stops"]] == ["FRA", "B", "A"]
    assert [l["mode"] for l in v["legs"]] == modes_before
    assert len(v["legs"]) == len(v["stops"]) - 1


def test_move_stop_at_edges_is_noop():
    v = _variant_3_stops()
    before = [s["ref"]["name"] for s in v["stops"]]
    assert itin.move_stop(v, 0, -1) == 0
    assert itin.move_stop(v, 2, +1) == 2
    assert [s["ref"]["name"] for s in v["stops"]] == before


def test_add_stop_inserts_matching_leg():
    v = _variant_3_stops()
    itin.add_stop(v, models.make_ref("custom", "C", "China", 30.5, 114.3),
                  at=1)
    assert [s["ref"]["name"] for s in v["stops"]] == ["FRA", "C", "A", "B"]
    assert len(v["legs"]) == 3
    # placeholder covers the new FRA->C gap; C->A inherits the old flight
    assert v["legs"][0]["mode"] == "flight"  # placeholder default
    assert v["legs"][1]["mode"] == "flight"
    assert v["legs"][2]["mode"] == "train"


def test_duplicate_variant_gets_new_ids():
    trip = sample.make_sample_trip()
    va = trip["variants"][0]
    clone = itin.duplicate_variant(trip, va["id"])
    assert clone["id"] != va["id"]
    assert clone["name"] == "Return via Beijing (copy)"
    old_ids = {s["id"] for s in va["stops"]}
    assert {s["id"] for s in clone["stops"]}.isdisjoint(old_ids)
    assert len(clone["stops"]) == len(va["stops"])


def test_delete_variant_keeps_one_and_fixes_active():
    trip = sample.make_sample_trip()
    vb = trip["variants"][1]
    itin.delete_variant(trip, vb["id"])
    assert len(trip["variants"]) == 1
    assert trip["active_variant_id"] == trip["variants"][0]["id"]
    itin.delete_variant(trip, trip["variants"][0]["id"])  # refused
    assert len(trip["variants"]) == 1


# ── totals / warnings ────────────────────────────────────────────────────────

def test_totals_counts_modes_and_dates():
    v = sample.make_sample_trip()["variants"][0]
    t = itin.totals(v)
    assert t["stops"] == 5
    assert t["flights"] == 3
    assert t["trains"] == 1
    assert t["nights"] == 10
    assert t["start"] == "2027-04-01"
    assert t["end"] == "2027-04-11"


def test_totals_nights_from_date_span_when_unset():
    v = models.make_variant("V", [
        models.make_stop(models.make_ref("custom", "A", "X", 1, 1),
                         arrival_date="2027-05-01",
                         departure_date="2027-05-04"),
        models.make_stop(models.make_ref("custom", "B", "X", 2, 2),
                         arrival_date="2027-05-04"),
    ], [models.make_leg()])
    assert itin.totals(v)["nights"] == 3


def test_warnings_cover_common_problems():
    v = models.make_variant("V", [
        models.make_stop(models.make_ref("custom", "NoCoords", "X"),
                         arrival_date="2027-05-05",
                         departure_date="2027-05-01"),  # dep < arr
        models.make_stop(models.make_ref("custom", "OnlyDep", "Y", 1, 1),
                         departure_date="2027-05-02"),  # dep w/o arr
        models.make_stop(models.make_ref("gateway", "Start", "DE", 50, 8),
                         role="origin", departure_date="2027-05-02"),
    ], [])
    w = itin.warnings_for(v)
    assert any("NoCoords" in x and "coordinates" in x for x in w)
    assert any("NoCoords" in x and "departure before arrival" in x for x in w)
    assert any("OnlyDep" in x for x in w)
    # origin with only a departure date is normal — no warning
    assert not any("Start" in x for x in w)


def test_route_summary_smoke():
    v = sample.make_sample_trip()["variants"][0]
    s = itin.route_summary(v)
    assert "5 stops" in s and "3 flights" in s and "1 trains" in s


# ── geo ──────────────────────────────────────────────────────────────────────

def test_bearing_frankfurt_to_beijing_is_northeast():
    b = geo.initial_bearing(50.1109, 8.6821, 39.9042, 116.4074)
    assert 40 <= b <= 90, b


def test_bearing_beijing_to_xian_is_southwest():
    b = geo.initial_bearing(39.9042, 116.4074, 34.3416, 108.9398)
    assert 200 <= b <= 280, b


def test_great_circle_midpoint_roughly_between():
    pts = geo.great_circle_points(50.0, 8.0, 40.0, 116.0, n=10)
    assert len(pts) == 11
    mid = pts[5]
    # great circle arcs POLEWARD: midpoint lat exceeds both endpoints
    assert 57 <= mid[0] <= 61, mid
    # non-linear lon progress (converging meridians), but between endpoints
    assert 65 <= mid[1] <= 73, mid
    assert abs(pts[0][0] - 50.0) < 1e-9 and abs(pts[0][1] - 8.0) < 1e-9
    assert abs(pts[-1][0] - 40.0) < 1e-9 and abs(pts[-1][1] - 116.0) < 1e-9


def test_direct_point_distance_consistency():
    # walking bearing 45° for 10° from (0,0) should land ~10° away
    lat2, lon2 = geo.direct_point(0.0, 0.0, 45.0, 10.0)
    d = geo.angular_distance_deg(0.0, 0.0, lat2, lon2)
    assert abs(d - 10.0) < 1e-6


def test_haversine_known_distance():
    # Frankfurt -> Beijing is roughly 7,800 km
    d = geo.haversine_km(50.1109, 8.6821, 39.9042, 116.4074)
    assert 7300 <= d <= 8300, d


def test_arrow_wings_shape_and_direction():
    pts = geo.great_circle_points(50.0, 8.0, 40.0, 116.0, n=24)
    wings = geo.arrow_wings(pts)
    # [tip, left, tip, right]
    assert len(wings) == 4
    tip, left, tip2, right = wings
    assert tip == tip2
    # tip should sit around 55% along the path (non-linear lon progress:
    # measured 66% in lon terms for this leg)
    pct = abs(tip[1] - 8.0) / abs(116.0 - 8.0) * 100
    assert 58 <= pct <= 74, pct
    # wings point BACKWARDS (behind the tip relative to travel)
    b_travel = geo.initial_bearing(pts[11][0], pts[11][1], tip[0], tip[1])
    b_wing = geo.initial_bearing(tip[0], tip[1], left[0], left[1])
    diff = abs((b_wing - b_travel + 180) % 360 - 180)
    assert 100 <= diff <= 180, diff  # roughly opposite travel direction


def test_fit_view_frames_and_pads():
    # China-only frame with minimum padding
    view = geo.fit_view([(39.9, 116.4), (31.2, 121.5)])
    lo, hi = view["lonaxis"]["range"]
    assert 112 <= lo <= 117 and 120 <= hi <= 126
    assert 27 <= view["lataxis"]["range"][0] <= 32
    # a far point (Frankfurt) pulls the frame wide to include it
    view2 = geo.fit_view([(50.1, 8.7), (39.9, 116.4)])
    lo2, hi2 = view2["lonaxis"]["range"]
    assert lo2 < 8 and hi2 > 120
    # empty input -> safe world fallback
    empty = geo.fit_view([])
    assert empty["lonaxis"]["range"] == [-140, 140]


def test_resolve_ref_from_coords_index():
    idx = {"xi'an": {"name": "Xi'an", "country": "China", "lat": 34.34,
                     "lon": 108.94},
           "xian": {"name": "Xi'an", "country": "China", "lat": 34.34,
                    "lon": 108.94}}
    ref = geo.resolve_ref({"kind": "custom", "name": "  XI'AN "}, idx)
    assert ref["lat"] == 34.34 and ref["country"] == "China"
    # punctuation-stripped lookup works too ("Xian" matches "Xi'an")
    ref2 = geo.resolve_ref({"kind": "custom", "name": "Xian"},
                           {"xian": idx["xian"]})
    assert ref2["lat"] == 34.34
    # already-resolved refs pass through untouched
    ref3 = geo.resolve_ref({"kind": "custom", "name": "A", "lat": 1.0,
                            "lon": 2.0}, idx)
    assert ref3 == {"kind": "custom", "name": "A", "lat": 1.0, "lon": 2.0}


# ── suggested months (needs the real workbook coordinates file only) ────────

def test_suggested_months_uses_workbook_shape():
    import pandas as pd
    df = pd.DataFrame({
        "Destination": ["Kyoto", "Nowhere"],
        "January": ["", ""], "February": ["", ""], "March": ["", ""],
        "April": ["ideal", ""], "May": ["good", ""], "June": ["hot", ""],
        "July": ["hot", ""], "August": ["hot", ""], "September": ["good", ""],
        "October": ["ideal", ""], "November": ["", ""], "December": ["", ""],
    })
    v = models.make_variant("V", [
        models.make_stop(models.make_ref("destination", "Kyoto", "Japan")),
        models.make_stop(models.make_ref("destination", "Nowhere", "X")),
        models.make_stop(models.make_ref("gateway", "FRA", "Germany")),
    ], [])
    out = itin.suggested_months(v, df)
    assert out["Kyoto"] == ["April", "May", "September", "October"]
    assert "Nowhere" not in out  # unknown destination -> no entry


def test_suggested_months_matches_normalised_names():
    import pandas as pd
    df = pd.DataFrame({
        "Destination": ["Xi'an (Shaanxi)"],
        "January": [""], "February": [""], "March": [""],
        "April": ["ideal"], "May": ["good"], "June": ["hot"],
        "July": ["hot"], "August": ["hot"], "September": ["good"],
        "October": ["ideal"], "November": [""], "December": [""],
    })
    v = models.make_variant("V", [
        models.make_stop(models.make_ref("destination", "Xi'an", "China")),
    ], [])
    out = itin.suggested_months(v, df)
    assert out["Xi'an"] == ["April", "May", "September", "October"]


# ── map ──────────────────────────────────────────────────────────────────────

def test_map_builds_traces_and_theme():
    v = sample.make_sample_trip()["variants"][0]
    fig = itmap.build_figure(v)
    names = [t.name for t in fig.data if t.showlegend]
    assert any("Flight" in n and "(3)" in n for n in names)
    assert any("Train" in n and "(1)" in n for n in names)
    geo_cfg = fig.layout.geo
    assert geo_cfg.projection.type == "natural earth"
    assert geo_cfg.showcountries is True
    # framed on China, not Frankfurt
    lo, hi = geo_cfg.lonaxis.range
    assert lo > 100 and hi < 130
    # selected halo appears when a stop id is passed
    stop_id = v["stops"][2]["id"]
    fig2 = itmap.build_figure(v, selected_stop_id=stop_id)
    assert len(fig2.data) == len(fig.data) + 1


# ── storage ──────────────────────────────────────────────────────────────────

def test_storage_roundtrip_and_seed():
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "trips.json"
        assert not path.exists()
        data = storage.ensure_seed(path)
        assert len(data["trips"]) == 1
        assert path.exists()
        again = storage.load_from(path)
        assert again["trips"][0]["name"] == "China Trip 2027"
        # roundtrip preserves ids
        assert again["trips"][0]["id"] == data["trips"][0]["id"]
        # corrupt file -> .corrupt.bak + empty store
        path.write_text("{not json", encoding="utf-8")
        ok = storage.load_from(path)
        assert ok["trips"] == []
        assert path.with_suffix(".corrupt.bak").exists()


def test_export_trip_is_valid_json():
    import json
    trip = sample.make_sample_trip()
    parsed = json.loads(storage.export_trip(trip))
    assert parsed["name"] == "China Trip 2027"
    assert len(parsed["variants"]) == 2


def test_backups_snapshot_and_restore():
    """Saving keeps a snapshot of the outgoing file; restore brings it back."""
    import json
    real_path, real_dir = storage.TRIPS_PATH, storage.BACKUP_DIR
    with tempfile.TemporaryDirectory() as td:
        storage.TRIPS_PATH = Path(td) / "trips.json"
        storage.BACKUP_DIR = Path(td) / "trips_backups"
        try:
            one = sample.make_sample_trip()
            two = sample.make_sample_trip()
            two["name"] = "Second trip"
            storage.save_trips({"schema_version": 1, "trips": [one]})
            assert storage.list_backups() == []      # nothing to back up yet
            storage.save_trips({"schema_version": 1, "trips": [one, two]})
            backups = storage.list_backups()
            assert len(backups) == 1
            assert "China Trip 2027" in " ".join(backups[0]["trips"])
            assert "Second trip" not in " ".join(backups[0]["trips"])
            # the second trip is deleted -> the newest snapshot holds both
            storage.save_trips({"schema_version": 1, "trips": [one]})
            backups = storage.list_backups()
            assert len(backups) == 2
            assert "Second trip" in " ".join(backups[0]["trips"])
            storage.restore_backup(backups[0]["path"])
            names = [t["name"] for t in storage.load_trips()["trips"]]
            assert names == ["China Trip 2027", "Second trip"]
        finally:
            storage.TRIPS_PATH, storage.BACKUP_DIR = real_path, real_dir


def test_backups_skip_identical_and_prune():
    """Repeated identical saves don't pile up; old snapshots are pruned."""
    with tempfile.TemporaryDirectory() as td:
        real_path, real_dir, real_keep = (storage.TRIPS_PATH,
                                          storage.BACKUP_DIR,
                                          storage.BACKUP_KEEP)
        storage.TRIPS_PATH = Path(td) / "trips.json"
        storage.BACKUP_DIR = Path(td) / "trips_backups"
        storage.BACKUP_KEEP = 3
        try:
            trip = sample.make_sample_trip()
            # distinct contents each time -> a snapshot per change
            for extra in range(6):
                variants = trip["variants"][: 1 + (extra % 2)]
                doc = {"schema_version": 1,
                       "trips": [dict(trip, variants=variants,
                                      active_variant_id=variants[0]["id"])]}
                storage.save_trips(doc)
            assert len(storage.list_backups()) <= 3
            # saving the identical content twice adds no new snapshot
            doc = storage.load_trips()
            before = len(storage.list_backups())
            storage.save_trips(doc)
            assert len(storage.list_backups()) == before
        finally:
            storage.TRIPS_PATH = real_path
            storage.BACKUP_DIR = real_dir
            storage.BACKUP_KEEP = real_keep


def test_ui_state_roundtrip():
    """The open trip survives a 'reload' (new session) via ui_state.json."""
    real_ui, real_dir = storage.UI_STATE_PATH, storage.CACHE_DIR
    with tempfile.TemporaryDirectory() as td:
        storage.CACHE_DIR = Path(td)
        storage.UI_STATE_PATH = Path(td) / "ui_state.json"
        try:
            assert storage.load_ui_state() == {}
            storage.save_ui_state({"active_trip_id": "trip-abc"})
            assert storage.load_ui_state()["active_trip_id"] == "trip-abc"
        finally:
            storage.UI_STATE_PATH, storage.CACHE_DIR = real_ui, real_dir


# ── __main__ runner (no pytest in this project) ─────────────────────────────

if __name__ == "__main__":
    failures = 0
    tests = [(n, f) for n, f in sorted(globals().items())
             if n.startswith("test_") and callable(f)]
    for name, fn in tests:
        try:
            fn()
            print(f"  PASS  {name}")
        except Exception as exc:  # noqa: BLE001
            failures += 1
            print(f"  FAIL  {name}: {type(exc).__name__}: {exc}")
    print(f"\n{len(tests) - failures}/{len(tests)} passed")
    sys.exit(1 if failures else 0)
