import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  attachMeetingHr,
  dayFromHeartrateDoc,
  downsampleDayHr,
  isHrSpike,
  noHrCoverage,
  parseHeartrateDoc,
  samplesInWindow,
  scoreMeetingHr,
  thinHrSeries,
  type HrSample,
} from "../src/lib/heartrate.ts";
import {
  filterHeartrateRowsForDays,
  paddedHeartrateDays,
  rawRowOverlapsDays,
} from "../src/lib/heartrate-archive.ts";

function sample(partial: Partial<HrSample> & Pick<HrSample, "bpm" | "timestamp">): HrSample {
  const timestampMs = Date.parse(partial.timestamp);
  return {
    source: partial.source ?? "awake",
    timestampMs,
    ...partial,
  };
}

function grid(day: string, startHour: number, hours: number, bpm: number, everyMin = 5): HrSample[] {
  const out: HrSample[] = [];
  for (let m = 0; m < hours * 60; m += everyMin) {
    const hh = String(startHour + Math.floor(m / 60)).padStart(2, "0");
    const mm = String(m % 60).padStart(2, "0");
    out.push(sample({ bpm, timestamp: `${day}T${hh}:${mm}:00-04:00`, source: "awake" }));
  }
  return out;
}

describe("parseHeartrateDoc", () => {
  it("reads a fixture day bundle and a single production sample", () => {
    const bundle = parseHeartrateDoc({
      id: "hr-2026-09-21",
      day: "2026-09-21",
      data: [
        { bpm: 58, source: "sleep", timestamp: "2026-09-21T03:00:00-04:00" },
        { bpm: 88, source: "awake", timestamp: "2026-09-21T10:00:00-04:00" },
      ],
    });
    assert.equal(bundle.length, 2);
    assert.equal(bundle[1].bpm, 88);

    const one = parseHeartrateDoc({
      bpm: 91,
      source: "awake",
      timestamp: "2026-09-21T14:05:00-04:00",
    });
    assert.equal(one.length, 1);
    assert.equal(one[0].bpm, 91);
    assert.equal(dayFromHeartrateDoc({ bpm: 91, timestamp: "2026-09-21T14:05:00-04:00" }), "2026-09-21");
  });

  it("ignores junk bpm and missing timestamps", () => {
    assert.deepEqual(parseHeartrateDoc({ bpm: 0, timestamp: "2026-09-21T10:00:00Z" }), []);
    assert.deepEqual(parseHeartrateDoc({ bpm: 80 }), []);
    assert.deepEqual(parseHeartrateDoc(null), []);
  });
});

describe("in-meeting HR proxy", () => {
  const day = [
    ...grid("2026-09-21", 8, 2, 70),
    ...grid("2026-09-21", 10, 1, 96),
    ...grid("2026-09-21", 11, 3, 72),
  ];

  it("scores an elevated meeting window and labels the method as a proxy", () => {
    const window = samplesInWindow(day, "2026-09-21T14:00:00.000Z", "2026-09-21T15:00:00.000Z");
    assert.ok(window.length >= 10);
    const scored = scoreMeetingHr(window, day, 52);
    assert.equal(scored.coverage, "ok");
    assert.equal(scored.method, "heartrate_proxy");
    assert.match(scored.methodNote, /not Oura's daytime stress/i);
    assert.equal(scored.headline, "Elevated");
    assert.equal(scored.zone, "high");
    assert.ok((scored.meanBpm ?? 0) >= 90);
    assert.ok((scored.elevatedPct ?? 0) >= 50);
    assert.ok(scored.impact > 0);
    assert.ok(isHrSpike(scored));
    assert.doesNotMatch(scored.headline, /thin night|heavy calendar/i);
    assert.match(scored.story, /beats per minute/i);
    assert.match(scored.story, /above your usual daytime average/i);
    assert.doesNotMatch(scored.story, /\bmean\b/i);
    assert.doesNotMatch(scored.methodNote, /\bmean\b/i);
    assert.ok(scored.series.length > 0);
  });

  it("scores a calm window as Restored", () => {
    const window = samplesInWindow(day, "2026-09-21T15:00:00.000Z", "2026-09-21T16:00:00.000Z");
    const scored = scoreMeetingHr(window, day, 52);
    assert.equal(scored.headline, "Restored");
    assert.equal(scored.zone, "low");
    assert.equal(isHrSpike(scored), false);
  });

  it("does not invent coverage when the window is empty", () => {
    const scored = scoreMeetingHr([], day, 52);
    assert.deepEqual(scored.headline, noHrCoverage().headline);
    assert.equal(scored.coverage, "none");
    assert.equal(scored.headline, "No ring HR in this window");
    assert.equal(scored.impact, 0);
  });

  it("ranks the spiked meeting above the calm one", () => {
    const map = attachMeetingHr(
      [
        {
          id: "pitch",
          startUtc: "2026-09-21T14:00:00.000Z",
          endUtc: "2026-09-21T15:00:00.000Z",
          day: "2026-09-21",
        },
        {
          id: "stand",
          startUtc: "2026-09-21T15:00:00.000Z",
          endUtc: "2026-09-21T16:00:00.000Z",
          day: "2026-09-21",
        },
        {
          id: "empty",
          startUtc: "2026-09-22T14:00:00.000Z",
          endUtc: "2026-09-22T15:00:00.000Z",
          day: "2026-09-22",
        },
      ],
      day,
      new Map([["2026-09-21", 52]]),
    );
    assert.ok((map.get("pitch")?.impact ?? 0) > (map.get("stand")?.impact ?? 0));
    assert.equal(map.get("empty")?.headline, "No ring HR in this window");
  });

  it("downsamples a day into buckets", () => {
    const series = downsampleDayHr(grid("2026-09-21", 10, 1, 80, 5), 15);
    assert.ok(series.length >= 3);
    assert.ok(series.every((p) => p.bpm === 80));
  });
});

describe("raw_object day filter", () => {
  it("keeps fixture keys for the requested days only", () => {
    assert.equal(
      rawRowOverlapsDays({ r2_key: "k", day: "2026-09-21", document_id: "hr-2026-09-21" }, "2026-09-20", "2026-09-22"),
      true,
    );
    assert.equal(
      rawRowOverlapsDays({ r2_key: "k", day: null, document_id: "hr-2026-09-21-p0" }, "2026-09-20", "2026-09-22"),
      true,
    );
    assert.equal(
      rawRowOverlapsDays({ r2_key: "k", day: "2026-08-01", document_id: "hr-2026-08-01" }, "2026-09-20", "2026-09-22"),
      false,
    );
  });

  it("keeps only meeting days plus a one-day pad", () => {
    assert.deepEqual(paddedHeartrateDays(["2026-09-21", "2026-09-01"]), [
      "2026-08-31",
      "2026-09-01",
      "2026-09-02",
      "2026-09-20",
      "2026-09-21",
      "2026-09-22",
    ]);
    const rows = [
      { r2_key: "a", day: "2026-09-01", document_id: "hr-2026-09-01" },
      { r2_key: "b", day: "2026-09-10", document_id: "hr-2026-09-10" },
      { r2_key: "c", day: null, document_id: "hr-2026-09-21-p0" },
    ];
    assert.deepEqual(
      filterHeartrateRowsForDays(rows, ["2026-09-21"]).map((r) => r.r2_key),
      ["c"],
    );
  });
});

describe("thinHrSeries", () => {
  it("keeps short series and downsamples long ones", () => {
    const short = [
      { t: "2026-09-21T14:00:00.000Z", bpm: 80, minutes: 0 },
      { t: "2026-09-21T14:05:00.000Z", bpm: 82, minutes: 0 },
    ];
    assert.equal(thinHrSeries(short, 24).length, 2);
    const long = Array.from({ length: 80 }, (_, i) => ({
      t: `2026-09-21T14:${String(i).padStart(2, "0")}:00.000Z`,
      bpm: 70 + i,
      minutes: 0,
    }));
    const thin = thinHrSeries(long, 24);
    assert.ok(thin.length <= 24);
    assert.equal(thin[0].bpm, 70);
    assert.equal(thin[thin.length - 1].bpm, 70 + 79);
  });
});
