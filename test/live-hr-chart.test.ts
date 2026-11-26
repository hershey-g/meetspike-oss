import assert from "node:assert/strict";
import test from "node:test";
import { liveChartData, liveChartHtml, meetingLiveWindow, mergeLivePoints, plotSegment } from "../public/live-hr.js";

const MINUTE = 60_000;
const START = Date.parse("2026-01-20T16:00:00Z");
const END = START + 30 * MINUTE;
const meeting = { startUtc: new Date(START).toISOString(), endUtc: new Date(END).toISOString(), sourceType: "calendar" };
const window = { fromMs: START - 10 * MINUTE, startMs: START, endMs: END, toMs: END + 10 * MINUTE };

test("live chart only uses supported meetings and includes ten minutes on both sides", () => {
  assert.deepEqual(meetingLiveWindow(meeting), window);
  assert.equal(meetingLiveWindow({ ...meeting, sourceType: "plaud_phone" }), null);
  assert.equal(meetingLiveWindow({ ...meeting, endUtc: "invalid" }), null);
  assert.equal(meetingLiveWindow({ ...meeting, endUtc: meeting.startUtc }), null);
  assert.equal(meetingLiveWindow({ ...meeting, endUtc: new Date(START + 24 * 60 * MINUTE).toISOString() }), null);
});

test("live chart merges pages and corrections in timestamp order", () => {
  const initial = [[START, 72], [START + 3000, 73]];
  const batch = [[START + 4000, 77], [START, 74], [START + 2000, 75], [START + 2000, 76]];
  assert.deepEqual(mergeLivePoints(initial, batch), [[START, 74], [START + 2000, 76], [START + 3000, 73], [START + 4000, 77]]);
  assert.deepEqual(initial, [[START, 72], [START + 3000, 73]]);
  assert.equal(mergeLivePoints(initial, []), initial);
});

test("live chart measures during-meeting stats, clips future and outside points, and does not bridge gaps", () => {
  const points = [[window.fromMs - 1, 200], [window.fromMs, 55], [START, 75], [START + 15_000, 82],
    [START + 31_000, 99], [END, 80], [END + 5000, 105], [END + 6000, 120]];
  const model = liveChartData(points, window, END + 5000);
  assert.equal(model.current, 105);
  assert.deepEqual(model.stats, { min: 75, avg: 84, max: 99 });
  assert.deepEqual(model.extent, [55, 105]);
  assert.deepEqual(model.segments.map((group: unknown[]) => group.length), [1, 2, 1, 2]);
  assert.equal(liveChartData(points, window, END + 51_000).current, null);
  assert.equal(liveChartData(points, window, START - 1).stats, null);
  assert.equal(liveChartData([], window, END).last, null);
  assert.match(liveChartHtml([], window, START, "UTC"), /Waiting for Meetspike HR/);
  assert.match(liveChartHtml(points, window, END + MINUTE, "UTC"), /Last reading/);
});

test("plot buckets preserve the endpoints, troughs, and peaks in order", () => {
  assert.deepEqual(plotSegment([[1, 70], [2, 120], [3, 55], [4, 90], [10, 80], [11, 80]], 10),
    [[1, 70], [2, 120], [3, 55], [10, 80], [11, 80]]);
  assert.deepEqual(plotSegment([[1, 70], [3, 65]], 10), [[1, 70], [3, 65]]);
  assert.deepEqual(plotSegment([], 10), []);
});
