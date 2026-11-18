import {
  SOURCE_TYPE_PLAUD_BOTH,
  SOURCE_TYPE_PLAUD_PHONE,
  SOURCE_TYPE_PLAUD_TAGGED,
  type EventSourceType,
} from "../../lib/source-type.ts";

const PHONE_TITLE = /^Phone Call:/i;
const MEETSPIKE_TAG = /\[meetspike\]/i;

export type PlaudMatch = {
  sourceType: Exclude<EventSourceType, "calendar">;
  syncReason: "phone_title" | "tag" | "phone_title,tag";
  kind: "phone" | "tagged";
};

/** Only Phone Call: titles and titles containing [meetspike] are in scope. */
export function classifyPlaudTitle(title: string): PlaudMatch | null {
  const phone = PHONE_TITLE.test(title);
  const tagged = MEETSPIKE_TAG.test(title);
  if (!phone && !tagged) return null;
  if (phone && tagged) {
    return { sourceType: SOURCE_TYPE_PLAUD_BOTH, syncReason: "phone_title,tag", kind: "phone" };
  }
  if (phone) return { sourceType: SOURCE_TYPE_PLAUD_PHONE, syncReason: "phone_title", kind: "phone" };
  return { sourceType: SOURCE_TYPE_PLAUD_TAGGED, syncReason: "tag", kind: "tagged" };
}

export function cleanPlaudTitle(title: string): string {
  return title.replace(/\s+/g, " ").trim().slice(0, 240);
}
