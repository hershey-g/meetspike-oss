import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  RANGE_MAX_SPAN_DAYS,
  daysInRange,
  isValidDay,
  parseDateRange,
  spanDays,
  validateDateRange,
} from "../src/lib/date-range.ts";
import { addCalendarDays } from "../src/lib/time.ts";

const TODAY = "2026-11-17";

describe("isValidDay", () => {
  it("accepts real calendar dates only", () => {
    assert.equal(isValidDay("2026-11-17"), true);
    assert.equal(isValidDay("2028-02-29"), true);
    assert.equal(isValidDay("2026-02-30"), false);
    assert.equal(isValidDay("2026-13-01"), false);
    assert.equal(isValidDay("17-11-2026"), false);
    assert.equal(isValidDay("2026-11-17T00:00:00Z"), false);
    assert.equal(isValidDay("yesterday"), false);
    assert.equal(isValidDay(undefined), false);
  });
});

describe("spanDays / daysInRange", () => {
  it("counts inclusively across months, years and DST changes", () => {
    assert.equal(spanDays("2026-11-17", "2026-11-17"), 1);
    assert.equal(spanDays("2026-11-01", "2026-12-31"), 61);
    assert.equal(spanDays("2026-12-31", "2027-01-01"), 2);
    // US DST ends 2026-11-01; calendar arithmetic must not drift.
    assert.equal(spanDays("2026-10-31", "2026-11-02"), 3);
    assert.deepEqual(daysInRange("2026-10-31", "2026-11-02"), ["2026-10-31", "2026-11-01", "2026-11-02"]);
    assert.deepEqual(daysInRange("2026-11-17", "2026-11-17"), ["2026-11-17"]);
  });
});

describe("parseDateRange — validation", () => {
  it("accepts a start/end span", () => {
    assert.deepEqual(parseDateRange({ start: "2026-11-01", end: "2026-12-31" }, { today: TODAY }), {
      start: "2026-11-01",
      end: "2026-12-31",
      spanDays: 61,
    });
  });

  it("rejects end before start", () => {
    assert.deepEqual(parseDateRange({ start: "2026-11-10", end: "2026-11-09" }, { today: TODAY }), {
      error: "end must be on or after start",
    });
  });

  it("rejects unparseable and impossible dates, naming the parameter", () => {
    assert.deepEqual(parseDateRange({ start: "nope", end: "2026-11-09" }, { today: TODAY }), {
      error: "start must be a valid YYYY-MM-DD date",
    });
    assert.deepEqual(parseDateRange({ start: "2026-11-01", end: "11/09/2026" }, { today: TODAY }), {
      error: "end must be a valid YYYY-MM-DD date",
    });
    assert.deepEqual(parseDateRange({ start: "2026-02-30", end: "2026-03-02" }, { today: TODAY }), {
      error: "start must be a valid YYYY-MM-DD date",
    });
    assert.deepEqual(parseDateRange({ date: "2026-1-5" }, { today: TODAY }), {
      error: "date must be a valid YYYY-MM-DD date",
    });
  });

  it("rejects mixing date with start/end", () => {
    assert.deepEqual(parseDateRange({ date: "2026-11-05", start: "2026-11-01" }, { today: TODAY }), {
      error: "use either date or start/end, not both",
    });
  });
});

describe("parseDateRange — span cap", () => {
  it("caps at 92 inclusive days", () => {
    assert.equal(RANGE_MAX_SPAN_DAYS, 92);
    const start = "2026-08-01";
    const atCap = addCalendarDays(start, RANGE_MAX_SPAN_DAYS - 1);
    assert.deepEqual(parseDateRange({ start, end: atCap }, { today: TODAY }), {
      start,
      end: atCap,
      spanDays: 92,
    });
    assert.deepEqual(parseDateRange({ start, end: addCalendarDays(atCap, 1) }, { today: TODAY }), {
      error: "range cannot exceed 92 days (got 93)",
    });
  });

  it("honours a caller-supplied cap", () => {
    assert.deepEqual(validateDateRange("2026-11-01", "2026-11-08", 7), {
      error: "range cannot exceed 7 days (got 8)",
    });
    assert.deepEqual(validateDateRange("2026-11-01", "2026-11-07", 7), {
      start: "2026-11-01",
      end: "2026-11-07",
      spanDays: 7,
    });
  });
});

describe("parseDateRange — single-day compatibility", () => {
  const oneDay = { start: "2026-11-05", end: "2026-11-05", spanDays: 1 };

  it("treats the legacy date parameter as a one-day range", () => {
    assert.deepEqual(parseDateRange({ date: "2026-11-05" }, { today: TODAY }), oneDay);
  });

  it("treats start = end as a one-day range", () => {
    assert.deepEqual(parseDateRange({ start: "2026-11-05", end: "2026-11-05" }, { today: TODAY }), oneDay);
  });

  it("treats a lone start or a lone end as a one-day range", () => {
    assert.deepEqual(parseDateRange({ start: "2026-11-05" }, { today: TODAY }), oneDay);
    assert.deepEqual(parseDateRange({ end: "2026-11-05" }, { today: TODAY }), oneDay);
    assert.deepEqual(parseDateRange({ start: "2026-11-05", end: "" }, { today: TODAY }), oneDay);
  });

  it("defaults to today when nothing is given, or to a trailing window on request", () => {
    assert.deepEqual(parseDateRange({}, { today: TODAY }), { start: TODAY, end: TODAY, spanDays: 1 });
    assert.deepEqual(parseDateRange({ start: " ", end: null }, { today: TODAY, defaultSpanDays: 7 }), {
      start: "2026-11-11",
      end: TODAY,
      spanDays: 7,
    });
  });
});
