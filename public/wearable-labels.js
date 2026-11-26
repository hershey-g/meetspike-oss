/** Source labels are shared by the meeting, range and person views. */
export function scoreLabel(wearable) {
  return `${wearable.readinessLabel} (${wearable.label})`;
}

export function meetingHrLabel(hr) {
  if (hr?.coverage !== "ok") return "";
  if (hr.source) return hr.source;
  // A cached response from the previous app version can still be on screen.
  return hr.methodNote?.includes("WHOOP") ? "WHOOP" : "Oura";
}
